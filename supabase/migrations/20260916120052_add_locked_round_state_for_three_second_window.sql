alter table public.game_rounds drop constraint if exists game_rounds_status_check;
alter table public.game_rounds add constraint game_rounds_status_check check (status in ('open','locked','closed','drawn','published'));

create or replace function public.jl_secure_number()
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_round_id uuid;
  v_lista    integer[];
  v_qtd      integer;
  v_sorteado integer;
  b          integer;
begin
  select id into v_round_id
  from public.game_rounds
  where status in ('open','locked')
  order by opened_at desc
  limit 1;

  if v_round_id is null then
    raise exception 'Nenhuma rodada ativa para sorteio.';
  end if;

  select array_agg(numero order by numero) into v_lista
  from (
    select n as numero, coalesce(sum(bt.amount), 0) as total
    from generate_series(0, 10) as n
    left join public.bets bt
      on bt.round_id = v_round_id and bt.selected_number = n
    group by n
  ) t
  where total = (select min(total) from (
    select coalesce(sum(bt.amount), 0) as total
    from generate_series(0, 10) as n
    left join public.bets bt
      on bt.round_id = v_round_id and bt.selected_number = n
    group by n
  ) x);

  v_qtd := coalesce(array_length(v_lista, 1), 0);
  if v_qtd = 0 then
    raise exception 'Sem candidatos.';
  end if;

  loop
    b := get_byte(extensions.gen_random_bytes(1), 0);
    if b < (256 - (256 % v_qtd)) then
      v_sorteado := v_lista[(b % v_qtd) + 1];
      return v_sorteado;
    end if;
  end loop;
end;
$$;

create or replace function public.jl_open_next_scheduled_round()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.draw_schedule%rowtype;
  v_round public.game_rounds%rowtype;
begin
  if exists (select 1 from public.game_rounds where status in ('open','locked','closed','drawn')) then
    return jsonb_build_object('opened', false, 'reason', 'active_round');
  end if;

  update public.draw_schedule
  set status = 'missed', updated_at = now()
  where status = 'pending'
    and draw_at <= now() + interval '3 seconds';

  select * into v_item
  from public.draw_schedule
  where status = 'pending'
  order by draw_at
  limit 1
  for update skip locked;

  if v_item.id is null then
    return jsonb_build_object('opened', false, 'reason', 'no_pending_schedule');
  end if;

  insert into public.game_rounds(status, closes_at, draw_at, schedule_id)
  values ('open', v_item.draw_at - interval '3 seconds', v_item.draw_at, v_item.id)
  returning * into v_round;

  update public.draw_schedule
  set status = 'active', round_id = v_round.id, updated_at = now()
  where id = v_item.id;

  return jsonb_build_object('opened', true, 'round_no', v_round.round_no, 'closes_at', v_round.closes_at, 'draw_at', v_round.draw_at, 'schedule_id', v_item.id);
end;
$$;

create or replace function public.jl_finalize_due_rounds()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round public.game_rounds%rowtype;
  v_number integer;
  v_count integer := 0;
begin
  for v_round in
    select *
    from public.game_rounds
    where status in ('open','locked','closed')
      and drawn_number is null
      and draw_at <= now()
    order by draw_at, opened_at
    for update skip locked
  loop
    v_number := public.jl_secure_number();

    update public.game_rounds
    set status = 'published',
        closed_at = coalesce(closed_at, closes_at),
        drawn_number = v_number,
        drawn_at = now(),
        published_at = now()
    where id = v_round.id;

    update public.bets
    set won = (selected_number = v_number),
        payout = case when selected_number = v_number then round(amount * 10, 2) else 0 end
    where round_id = v_round.id;

    update public.players p
    set balance = p.balance + w.total,
        updated_at = now()
    from (
      select player_id, sum(payout) as total
      from public.bets
      where round_id = v_round.id and won = true
      group by player_id
    ) w
    where p.id = w.player_id;

    insert into public.transactions(player_id, kind, amount, status, reference_id, note)
    select player_id, 'payout', payout, 'completed', id,
           'Prêmio automático da rodada ' || v_round.round_no
    from public.bets
    where round_id = v_round.id and won = true and payout > 0;

    if v_round.schedule_id is not null then
      update public.draw_schedule
      set status = 'completed', updated_at = now()
      where id = v_round.schedule_id;
    end if;

    insert into public.audit_log(action, details)
    values ('round.auto_draw_published', jsonb_build_object(
      'round_id', v_round.id,
      'round_no', v_round.round_no,
      'drawn_number', v_number,
      'bet_lock_at', v_round.closes_at,
      'scheduled_draw_at', v_round.draw_at,
      'processed_at', now()
    ));

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

create or replace function public.jl_process_game_engine()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_locked integer := 0;
  v_drawn integer := 0;
  v_opened jsonb;
begin
  if not pg_try_advisory_xact_lock(740112337) then
    return jsonb_build_object('busy', true, 'processed_at', now());
  end if;

  update public.game_rounds
  set status = 'locked',
      closed_at = coalesce(closed_at, closes_at)
  where status = 'open'
    and closes_at <= now()
    and drawn_number is null;
  get diagnostics v_locked = row_count;

  v_drawn := public.jl_finalize_due_rounds();
  v_opened := public.jl_open_next_scheduled_round();

  return jsonb_build_object('locked', v_locked, 'drawn', v_drawn, 'next', v_opened, 'processed_at', now());
end;
$$;

create or replace function public.jl_admin_open_round(p_token text, p_closes_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round public.game_rounds%rowtype;
  v_draw_at timestamptz := p_closes_at;
begin
  perform public.jl_require_admin(p_token);
  perform public.jl_process_game_engine();

  if v_draw_at is null or v_draw_at <= now() + interval '10 seconds' or v_draw_at > now() + interval '7 days' then
    raise exception 'Defina o sorteio entre 10 segundos e 7 dias a partir de agora.';
  end if;

  if exists(select 1 from public.game_rounds where status in ('open','locked','closed','drawn')) then
    raise exception 'Finalize a rodada atual antes de abrir outra manualmente.';
  end if;

  insert into public.game_rounds(status, closes_at, draw_at)
  values('open', v_draw_at - interval '3 seconds', v_draw_at)
  returning * into v_round;

  return jsonb_build_object('ok', true, 'round_no', v_round.round_no, 'closes_at', v_round.closes_at, 'draw_at', v_round.draw_at, 'message', 'Jogo aberto. As apostas serão bloqueadas 3 segundos antes do sorteio.');
end;
$$;

create or replace function public.jl_admin_close_round(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_round public.game_rounds%rowtype;
begin
  perform public.jl_require_admin(p_token);

  select * into v_round
  from public.game_rounds
  where status in ('open','locked','closed')
  order by opened_at desc
  limit 1
  for update;

  if v_round.id is null then raise exception 'Não há rodada ativa.'; end if;

  update public.game_rounds
  set status='locked',
      closed_at=now(),
      closes_at=least(closes_at, now()),
      draw_at=now()
  where id=v_round.id;

  perform public.jl_finalize_due_rounds();
  perform public.jl_process_game_engine();

  return jsonb_build_object('ok',true,'round_no',v_round.round_no,'message','Rodada encerrada e sorteada agora. A próxima programação foi ativada, se existir.');
end;
$$;

create or replace function public.jl_public_state()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round public.game_rounds%rowtype;
  v_last public.game_rounds%rowtype;
begin
  perform public.jl_process_game_engine();

  select * into v_round
  from public.game_rounds
  where status in ('open','locked','closed')
  order by opened_at desc limit 1;

  select * into v_last
  from public.game_rounds
  where status='published'
  order by published_at desc nulls last, opened_at desc limit 1;

  return jsonb_build_object(
    'server_time', now(),
    'current_round', case when v_round.id is null then null else jsonb_build_object(
      'id',v_round.id,'round_no',v_round.round_no,'status',v_round.status,'opened_at',v_round.opened_at,'closes_at',v_round.closes_at,'draw_at',v_round.draw_at
    ) end,
    'last_result', case when v_last.id is null then null else jsonb_build_object(
      'round_no',v_last.round_no,'drawn_number',v_last.drawn_number,'drawn_at',v_last.drawn_at,'published_at',v_last.published_at
    ) end
  );
end;
$$;

create or replace function public.jl_admin_dashboard(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round public.game_rounds%rowtype;
  v_last public.game_rounds%rowtype;
  v_stats jsonb;
  v_deposits jsonb;
  v_withdrawals jsonb;
  v_players jsonb;
  v_recent_bets jsonb;
  v_schedule jsonb;
begin
  perform public.jl_require_admin(p_token);
  perform public.jl_process_game_engine();

  select * into v_round from public.game_rounds where status in ('open','locked','closed') order by opened_at desc limit 1;
  select * into v_last from public.game_rounds where status='published' order by published_at desc nulls last, opened_at desc limit 1;

  select coalesce(jsonb_agg(jsonb_build_object('number',n,'bets',coalesce(s.bet_count,0),'total',coalesce(s.total,0)) order by n),'[]'::jsonb)
  into v_stats
  from generate_series(0,10) n
  left join (
    select selected_number,count(*)::int bet_count,sum(amount)::numeric total
    from public.bets where round_id=v_round.id group by selected_number
  ) s on s.selected_number=n;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_deposits
  from (select d.id,d.amount,d.note,d.status,d.created_at,p.name,p.phone from public.deposit_requests d join public.players p on p.id=d.player_id where d.status='pending' order by d.created_at desc limit 100) x;
  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_withdrawals
  from (select w.id,w.amount,w.status,w.reason,w.created_at,p.name,p.phone from public.withdrawal_requests w join public.players p on p.id=w.player_id where w.status='pending' order by w.created_at desc limit 100) x;
  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_players
  from (select id,name,phone,balance,blocked,created_at from public.players order by created_at desc limit 200) x;
  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_recent_bets
  from (select b.id,b.selected_number,b.amount,b.won,b.payout,b.created_at,p.name,p.phone,r.round_no from public.bets b join public.players p on p.id=b.player_id join public.game_rounds r on r.id=b.round_id order by b.created_at desc limit 100) x;
  select coalesce(jsonb_agg(x order by x.draw_at),'[]'::jsonb) into v_schedule
  from (select id,draw_at,status,round_id,created_at from public.draw_schedule where status in ('pending','active') order by draw_at limit 250) x;

  return jsonb_build_object(
    'server_time',now(),
    'lock_seconds',3,
    'round',case when v_round.id is null then null else jsonb_build_object('id',v_round.id,'round_no',v_round.round_no,'status',v_round.status,'opened_at',v_round.opened_at,'closes_at',v_round.closes_at,'draw_at',v_round.draw_at,'schedule_id',v_round.schedule_id) end,
    'last_result',case when v_last.id is null then null else jsonb_build_object('round_no',v_last.round_no,'drawn_number',v_last.drawn_number,'drawn_at',v_last.drawn_at,'published_at',v_last.published_at) end,
    'number_stats',v_stats,
    'draw_schedule',v_schedule,
    'pending_deposits',v_deposits,
    'pending_withdrawals',v_withdrawals,
    'players',v_players,
    'recent_bets',v_recent_bets
  );
end;
$$;

revoke execute on function public.jl_secure_number() from public;

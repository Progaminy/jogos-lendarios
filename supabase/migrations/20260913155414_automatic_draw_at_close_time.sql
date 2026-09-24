create extension if not exists pg_cron;

create or replace function public.jl_finalize_due_rounds()
returns integer
language plpgsql
security definer
set search_path = 'public'
as $function$
declare
  v_round public.game_rounds%rowtype;
  v_number integer;
  v_count integer := 0;
begin
  for v_round in
    select *
    from public.game_rounds
    where status in ('open','closed')
      and drawn_number is null
      and closes_at <= now()
    order by closes_at, opened_at
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

    insert into public.audit_log(action, details)
    values (
      'round.auto_draw_published',
      jsonb_build_object(
        'round_id', v_round.id,
        'round_no', v_round.round_no,
        'drawn_number', v_number,
        'scheduled_close', v_round.closes_at,
        'processed_at', now()
      )
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$function$;

revoke all on function public.jl_finalize_due_rounds() from public, anon, authenticated;

create or replace function public.jl_public_state()
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $function$
declare v_round public.game_rounds%rowtype;
declare v_last public.game_rounds%rowtype;
begin
  perform public.jl_finalize_due_rounds();

  select * into v_round
  from public.game_rounds
  where status in ('open','closed')
  order by opened_at desc limit 1;

  select * into v_last
  from public.game_rounds
  where status = 'published'
  order by published_at desc nulls last, opened_at desc limit 1;

  return jsonb_build_object(
    'server_time', now(),
    'current_round', case when v_round.id is null then null else jsonb_build_object(
      'id', v_round.id,
      'round_no', v_round.round_no,
      'status', v_round.status,
      'opened_at', v_round.opened_at,
      'closes_at', v_round.closes_at
    ) end,
    'last_result', case when v_last.id is null then null else jsonb_build_object(
      'round_no', v_last.round_no,
      'drawn_number', v_last.drawn_number,
      'drawn_at', v_last.drawn_at,
      'published_at', v_last.published_at
    ) end
  );
end;
$function$;

create or replace function public.jl_admin_dashboard(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $function$
declare v_round public.game_rounds%rowtype;
declare v_last public.game_rounds%rowtype;
declare v_stats jsonb;
declare v_deposits jsonb;
declare v_withdrawals jsonb;
declare v_players jsonb;
declare v_recent_bets jsonb;
begin
  perform public.jl_require_admin(p_token);
  perform public.jl_finalize_due_rounds();

  select * into v_round
  from public.game_rounds
  where status in ('open','closed')
  order by opened_at desc limit 1;

  select * into v_last
  from public.game_rounds
  where status='published'
  order by published_at desc nulls last, opened_at desc limit 1;

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

  return jsonb_build_object(
    'server_time',now(),
    'round',case when v_round.id is null then null else jsonb_build_object('id',v_round.id,'round_no',v_round.round_no,'status',v_round.status,'opened_at',v_round.opened_at,'closes_at',v_round.closes_at) end,
    'last_result',case when v_last.id is null then null else jsonb_build_object('round_no',v_last.round_no,'drawn_number',v_last.drawn_number,'drawn_at',v_last.drawn_at,'published_at',v_last.published_at) end,
    'number_stats',v_stats,
    'pending_deposits',v_deposits,
    'pending_withdrawals',v_withdrawals,
    'players',v_players,
    'recent_bets',v_recent_bets
  );
end;
$function$;

create or replace function public.jl_admin_close_round(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $function$
declare v_round public.game_rounds%rowtype;
begin
  perform public.jl_require_admin(p_token);
  select * into v_round from public.game_rounds where status='open' order by opened_at desc limit 1 for update;
  if v_round.id is null then raise exception 'Não há rodada aberta.'; end if;

  update public.game_rounds
  set status='closed', closed_at=now(), closes_at=now()
  where id=v_round.id;

  perform public.jl_finalize_due_rounds();
  return jsonb_build_object('ok',true,'round_no',v_round.round_no,'message','Apostas encerradas. O sorteio e a publicação foram executados automaticamente.');
end;
$function$;

create or replace function public.jl_admin_draw_round(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $function$
begin
  perform public.jl_require_admin(p_token);
  raise exception 'O sorteio é automático na hora definida para encerramento da rodada.';
end;
$function$;

create or replace function public.jl_admin_publish_round(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $function$
begin
  perform public.jl_require_admin(p_token);
  raise exception 'A publicação do resultado é automática junto com o sorteio.';
end;
$function$;

do $do$
declare v_jobid bigint;
begin
  for v_jobid in select jobid from cron.job where jobname = 'jogos_lendarios_auto_draw' loop
    perform cron.unschedule(v_jobid);
  end loop;
  perform cron.schedule(
    'jogos_lendarios_auto_draw',
    '* * * * *',
    $cron$select public.jl_finalize_due_rounds();$cron$
  );
end;
$do$;

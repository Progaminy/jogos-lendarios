-- Jogos Lendários
-- Separa Número Lendário e Dupla Lendária em motores independentes.
-- Cada jogo passa a ter rodadas, programação, bloqueio, resultado e configuração próprios.
-- Ambos mantêm a regra de segurança da casa: o sorteio só considera resultados que não gerem prejuízo
-- e novas apostas são recusadas se eliminarem a última opção segura da rodada.

alter table public.game_rounds
  add column if not exists game_type text not null default 'number';

alter table public.game_rounds drop constraint if exists game_rounds_game_type_check;
alter table public.game_rounds add constraint game_rounds_game_type_check
  check (game_type in ('number','pair'));

alter table public.draw_schedule
  add column if not exists game_type text not null default 'number';

alter table public.draw_schedule drop constraint if exists draw_schedule_game_type_check;
alter table public.draw_schedule add constraint draw_schedule_game_type_check
  check (game_type in ('number','pair'));

alter table public.draw_schedule drop constraint if exists draw_schedule_draw_at_key;
create unique index if not exists draw_schedule_game_draw_at_uidx
  on public.draw_schedule(game_type, draw_at);

create index if not exists game_rounds_game_status_draw_idx
  on public.game_rounds(game_type, status, draw_at);

create index if not exists draw_schedule_game_status_draw_idx
  on public.draw_schedule(game_type, status, draw_at);

create table if not exists public.game_settings (
  game_type text primary key check (game_type in ('number','pair')),
  min_bet numeric not null check (min_bet > 0),
  max_bet numeric not null check (max_bet >= min_bet),
  multiplier numeric not null check (multiplier > 1),
  lock_seconds integer not null check (lock_seconds between 1 and 60),
  draw_mode text not null check (draw_mode in ('house_min','house_safe_random')),
  enabled boolean not null default true,
  updated_at timestamptz not null default now()
);

alter table public.game_settings enable row level security;

insert into public.game_settings(game_type,min_bet,max_bet,multiplier,lock_seconds,draw_mode,enabled)
values
  ('number',10,500,10,3,'house_min',true),
  ('pair',10,500,50,3,'house_min',true)
on conflict (game_type) do nothing;

create or replace function public.jl_random_index(p_count integer)
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  b integer;
  limit_byte integer;
begin
  if p_count is null or p_count < 1 or p_count > 256 then
    raise exception 'Quantidade inválida para sorteio.';
  end if;

  limit_byte := 256 - (256 % p_count);
  loop
    b := get_byte(extensions.gen_random_bytes(1), 0);
    if b < limit_byte then
      return (b % p_count) + 1;
    end if;
  end loop;
end;
$$;

create or replace function public.jl_secure_number(p_round_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_settings public.game_settings%rowtype;
  v_total numeric;
  v_list integer[];
  v_count integer;
begin
  select * into v_settings from public.game_settings where game_type='number';

  if not exists (
    select 1 from public.game_rounds
    where id=p_round_id and game_type='number' and status in ('open','locked','closed')
  ) then
    raise exception 'Rodada válida do Número Lendário não encontrada.';
  end if;

  select coalesce(sum(amount),0) into v_total
  from public.bets where round_id=p_round_id;

  if v_settings.draw_mode='house_safe_random' and v_total > 0 then
    select array_agg(number order by number) into v_list
    from (
      select n as number, coalesce(sum(b.amount),0) as exposure
      from generate_series(0,10) n
      left join public.bets b on b.round_id=p_round_id and b.selected_number=n
      group by n
    ) x
    where exposure * v_settings.multiplier < v_total;
  else
    select array_agg(number order by number) into v_list
    from (
      select number, exposure,
             min(exposure) over () as min_exposure
      from (
        select n as number, coalesce(sum(b.amount),0) as exposure
        from generate_series(0,10) n
        left join public.bets b on b.round_id=p_round_id and b.selected_number=n
        group by n
      ) s
    ) x
    where exposure=min_exposure;
  end if;

  v_count := coalesce(array_length(v_list,1),0);
  if v_count=0 then
    raise exception 'Nenhum resultado seguro disponível para o Número Lendário.';
  end if;

  return v_list[public.jl_random_index(v_count)];
end;
$$;

create or replace function public.jl_secure_number()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_round_id uuid;
begin
  select id into v_round_id
  from public.game_rounds
  where game_type='number' and status in ('open','locked','closed')
  order by opened_at desc
  limit 1;

  if v_round_id is null then
    raise exception 'Nenhuma rodada ativa do Número Lendário.';
  end if;

  return public.jl_secure_number(v_round_id);
end;
$$;

create or replace function public.jl_secure_pair(p_round_id uuid)
returns integer[]
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_settings public.game_settings%rowtype;
  v_total numeric;
  v_list integer[];
  v_count integer;
  v_code integer;
begin
  select * into v_settings from public.game_settings where game_type='pair';

  if not exists (
    select 1 from public.game_rounds
    where id=p_round_id and game_type='pair' and status in ('open','locked','closed')
  ) then
    raise exception 'Rodada válida da Dupla Lendária não encontrada.';
  end if;

  select coalesce(sum(amount),0) into v_total
  from public.pair_bets where round_id=p_round_id;

  if v_settings.draw_mode='house_safe_random' and v_total > 0 then
    select array_agg(code order by code) into v_list
    from (
      select (a*100+b) as code, coalesce(sum(pb.amount),0) as exposure
      from generate_series(1,10) a
      cross join generate_series(1,10) b
      left join public.pair_bets pb
        on pb.round_id=p_round_id and pb.number_a=a and pb.number_b=b
      where a < b
      group by a,b
    ) x
    where exposure * v_settings.multiplier < v_total;
  else
    select array_agg(code order by code) into v_list
    from (
      select code, exposure, min(exposure) over () as min_exposure
      from (
        select (a*100+b) as code, coalesce(sum(pb.amount),0) as exposure
        from generate_series(1,10) a
        cross join generate_series(1,10) b
        left join public.pair_bets pb
          on pb.round_id=p_round_id and pb.number_a=a and pb.number_b=b
        where a < b
        group by a,b
      ) s
    ) x
    where exposure=min_exposure;
  end if;

  v_count := coalesce(array_length(v_list,1),0);
  if v_count=0 then
    raise exception 'Nenhuma combinação segura disponível para a Dupla Lendária.';
  end if;

  v_code := v_list[public.jl_random_index(v_count)];
  return array[(v_code / 100)::integer, (v_code % 100)::integer];
end;
$$;

create or replace function public.jl_place_bet(
  p_token text,
  p_selected_number integer,
  p_amount numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := public.jl_player_id(p_token);
  v_player public.players%rowtype;
  v_round public.game_rounds%rowtype;
  v_settings public.game_settings%rowtype;
  v_bet_id uuid;
  v_total_after numeric;
  v_min_after numeric;
begin
  select * into v_settings from public.game_settings where game_type='number';
  if not v_settings.enabled then raise exception 'Número Lendário está temporariamente desativado.'; end if;
  if p_selected_number < 0 or p_selected_number > 10 then raise exception 'Escolha um número de 0 a 10.'; end if;
  if p_amount is null or p_amount < v_settings.min_bet or p_amount > v_settings.max_bet then
    raise exception 'A aposta deve ser entre % e % MZN.', v_settings.min_bet, v_settings.max_bet;
  end if;

  select * into v_round
  from public.game_rounds
  where game_type='number' and status='open' and closes_at > now()
  order by opened_at desc limit 1 for update;
  if v_round.id is null then raise exception 'As apostas do Número Lendário estão fechadas neste momento.'; end if;

  select * into v_player from public.players where id=v_player_id for update;
  if v_player.blocked then raise exception 'Esta conta está bloqueada.'; end if;
  if v_player.balance < p_amount then raise exception 'Saldo insuficiente para esta aposta.'; end if;

  select coalesce(sum(amount),0) + p_amount into v_total_after
  from public.bets where round_id=v_round.id;

  select min(exposure) into v_min_after
  from (
    select n,
      coalesce(sum(b.amount),0) + case when n=p_selected_number then p_amount else 0 end as exposure
    from generate_series(0,10) n
    left join public.bets b on b.round_id=v_round.id and b.selected_number=n
    group by n
  ) x;

  if v_min_after * v_settings.multiplier >= v_total_after then
    raise exception 'Esta aposta atingiria o limite de segurança da rodada. Escolha outro número ou aguarde a próxima rodada.';
  end if;

  update public.players set balance=balance-p_amount, updated_at=now() where id=v_player_id;
  insert into public.bets(round_id,player_id,selected_number,amount)
  values(v_round.id,v_player_id,p_selected_number,round(p_amount,2))
  returning id into v_bet_id;

  insert into public.transactions(player_id,kind,amount,status,reference_id,note)
  values(v_player_id,'bet',-round(p_amount,2),'completed',v_bet_id,'Aposta no Número Lendário');

  return jsonb_build_object(
    'ok',true,'bet_id',v_bet_id,'round_no',v_round.round_no,
    'selected_number',p_selected_number,'amount',round(p_amount,2),
    'balance',v_player.balance-round(p_amount,2)
  );
end;
$$;

create or replace function public.jl_place_pair_bet(
  p_token text,
  p_number_a integer,
  p_number_b integer,
  p_amount numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := public.jl_player_id(p_token);
  v_player public.players%rowtype;
  v_round public.game_rounds%rowtype;
  v_settings public.game_settings%rowtype;
  v_bet_id uuid;
  v_a integer;
  v_b integer;
  v_total_after numeric;
  v_min_after numeric;
begin
  select * into v_settings from public.game_settings where game_type='pair';
  if not v_settings.enabled then raise exception 'Dupla Lendária está temporariamente desativada.'; end if;

  if p_number_a is null or p_number_b is null then raise exception 'Escolha dois números.'; end if;
  if p_number_a < 1 or p_number_a > 10 or p_number_b < 1 or p_number_b > 10 then
    raise exception 'Escolha dois números entre 1 e 10.';
  end if;
  if p_number_a = p_number_b then raise exception 'Escolha dois números diferentes.'; end if;

  v_a := least(p_number_a,p_number_b);
  v_b := greatest(p_number_a,p_number_b);

  if p_amount is null or p_amount < v_settings.min_bet or p_amount > v_settings.max_bet then
    raise exception 'A aposta deve ser entre % e % MZN.', v_settings.min_bet, v_settings.max_bet;
  end if;

  select * into v_round
  from public.game_rounds
  where game_type='pair' and status='open' and closes_at > now()
  order by opened_at desc limit 1 for update;
  if v_round.id is null then raise exception 'As apostas da Dupla Lendária estão fechadas neste momento.'; end if;

  select * into v_player from public.players where id=v_player_id for update;
  if v_player.blocked then raise exception 'Esta conta está bloqueada.'; end if;
  if v_player.balance < p_amount then raise exception 'Saldo insuficiente para esta aposta.'; end if;

  select coalesce(sum(amount),0) + p_amount into v_total_after
  from public.pair_bets where round_id=v_round.id;

  select min(exposure) into v_min_after
  from (
    select a,b,
      coalesce(sum(pb.amount),0)
      + case when a=v_a and b=v_b then p_amount else 0 end as exposure
    from generate_series(1,10) a
    cross join generate_series(1,10) b
    left join public.pair_bets pb
      on pb.round_id=v_round.id and pb.number_a=a and pb.number_b=b
    where a < b
    group by a,b
  ) x;

  if v_min_after * v_settings.multiplier >= v_total_after then
    raise exception 'Esta aposta atingiria o limite de segurança da rodada. Escolha outra combinação ou aguarde a próxima rodada.';
  end if;

  update public.players set balance=balance-p_amount, updated_at=now() where id=v_player_id;
  insert into public.pair_bets(round_id,player_id,number_a,number_b,amount)
  values(v_round.id,v_player_id,v_a,v_b,round(p_amount,2))
  returning id into v_bet_id;

  insert into public.transactions(player_id,kind,amount,status,reference_id,note)
  values(v_player_id,'bet',-round(p_amount,2),'completed',v_bet_id,'Aposta Dupla Lendária '||v_a||'+'||v_b);

  return jsonb_build_object(
    'ok',true,'bet_id',v_bet_id,'round_no',v_round.round_no,
    'number_a',v_a,'number_b',v_b,'amount',round(p_amount,2),
    'balance',v_player.balance-round(p_amount,2)
  );
end;
$$;

create or replace function public.jl_open_next_game_round(p_game_type text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.draw_schedule%rowtype;
  v_round public.game_rounds%rowtype;
  v_settings public.game_settings%rowtype;
begin
  select * into v_settings from public.game_settings where game_type=p_game_type;
  if v_settings.game_type is null then raise exception 'Jogo inválido.'; end if;
  if not v_settings.enabled then return jsonb_build_object('opened',false,'reason','disabled'); end if;

  if exists (
    select 1 from public.game_rounds
    where game_type=p_game_type and status in ('open','locked','closed','drawn')
  ) then
    return jsonb_build_object('opened',false,'reason','active_round');
  end if;

  update public.draw_schedule
  set status='missed', updated_at=now()
  where game_type=p_game_type and status='pending'
    and draw_at <= now() + make_interval(secs => v_settings.lock_seconds);

  select * into v_item
  from public.draw_schedule
  where game_type=p_game_type and status='pending'
  order by draw_at
  limit 1
  for update skip locked;

  if v_item.id is null then return jsonb_build_object('opened',false,'reason','no_pending_schedule'); end if;

  insert into public.game_rounds(game_type,status,closes_at,draw_at,schedule_id)
  values(p_game_type,'open',v_item.draw_at-make_interval(secs => v_settings.lock_seconds),v_item.draw_at,v_item.id)
  returning * into v_round;

  update public.draw_schedule
  set status='active',round_id=v_round.id,updated_at=now()
  where id=v_item.id;

  return jsonb_build_object(
    'opened',true,'game_type',p_game_type,'round_no',v_round.round_no,
    'closes_at',v_round.closes_at,'draw_at',v_round.draw_at,'schedule_id',v_item.id
  );
end;
$$;

create or replace function public.jl_finalize_game_due_rounds(p_game_type text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round public.game_rounds%rowtype;
  v_settings public.game_settings%rowtype;
  v_number integer;
  v_pair integer[];
  v_count integer := 0;
begin
  select * into v_settings from public.game_settings where game_type=p_game_type;
  if v_settings.game_type is null then raise exception 'Jogo inválido.'; end if;

  for v_round in
    select *
    from public.game_rounds
    where game_type=p_game_type
      and status in ('open','locked','closed')
      and draw_at <= now()
    order by draw_at,opened_at
    for update skip locked
  loop
    if p_game_type='number' then
      v_number := public.jl_secure_number(v_round.id);

      update public.game_rounds
      set status='published',
          closed_at=coalesce(closed_at,closes_at),
          drawn_number=v_number,
          drawn_at=now(),published_at=now()
      where id=v_round.id;

      update public.bets
      set won=(selected_number=v_number),
          payout=case when selected_number=v_number then round(amount*v_settings.multiplier,2) else 0 end
      where round_id=v_round.id;

      update public.players p
      set balance=p.balance+w.total,updated_at=now()
      from (
        select player_id,sum(payout) total
        from public.bets
        where round_id=v_round.id and won=true and payout>0
        group by player_id
      ) w
      where p.id=w.player_id;

      insert into public.transactions(player_id,kind,amount,status,reference_id,note)
      select player_id,'payout',payout,'completed',id,
             'Prêmio Número Lendário da rodada '||v_round.round_no
      from public.bets
      where round_id=v_round.id and won=true and payout>0;

      insert into public.audit_log(action,details)
      values('number.round_published',jsonb_build_object(
        'round_id',v_round.id,'round_no',v_round.round_no,
        'drawn_number',v_number,'draw_mode',v_settings.draw_mode,
        'multiplier',v_settings.multiplier,'processed_at',now()
      ));
    else
      v_pair := public.jl_secure_pair(v_round.id);

      update public.game_rounds
      set status='published',
          closed_at=coalesce(closed_at,closes_at),
          pair_drawn_a=v_pair[1],pair_drawn_b=v_pair[2],
          drawn_at=now(),published_at=now()
      where id=v_round.id;

      update public.pair_bets
      set won=(number_a=v_pair[1] and number_b=v_pair[2]),
          payout=case when number_a=v_pair[1] and number_b=v_pair[2]
                      then round(amount*v_settings.multiplier,2) else 0 end
      where round_id=v_round.id;

      update public.players p
      set balance=p.balance+w.total,updated_at=now()
      from (
        select player_id,sum(payout) total
        from public.pair_bets
        where round_id=v_round.id and won=true and payout>0
        group by player_id
      ) w
      where p.id=w.player_id;

      insert into public.transactions(player_id,kind,amount,status,reference_id,note)
      select player_id,'payout',payout,'completed',id,
             'Prêmio Dupla Lendária '||v_pair[1]||'+'||v_pair[2]||' da rodada '||v_round.round_no
      from public.pair_bets
      where round_id=v_round.id and won=true and payout>0;

      insert into public.audit_log(action,details)
      values('pair.round_published',jsonb_build_object(
        'round_id',v_round.id,'round_no',v_round.round_no,
        'pair_drawn_a',v_pair[1],'pair_drawn_b',v_pair[2],
        'draw_mode',v_settings.draw_mode,'multiplier',v_settings.multiplier,
        'processed_at',now()
      ));
    end if;

    if v_round.schedule_id is not null then
      update public.draw_schedule
      set status='completed',updated_at=now()
      where id=v_round.schedule_id;
    end if;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

create or replace function public.jl_process_game(p_game_type text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_locked integer := 0;
  v_drawn integer := 0;
  v_opened jsonb;
  v_lock_key bigint;
begin
  if p_game_type not in ('number','pair') then raise exception 'Jogo inválido.'; end if;
  v_lock_key := case when p_game_type='number' then 740112337 else 740112338 end;

  if not pg_try_advisory_xact_lock(v_lock_key) then
    return jsonb_build_object('busy',true,'game_type',p_game_type,'processed_at',now());
  end if;

  update public.game_rounds
  set status='locked',closed_at=coalesce(closed_at,closes_at)
  where game_type=p_game_type and status='open'
    and closes_at <= now() and (drawn_number is null and pair_drawn_a is null);
  get diagnostics v_locked=row_count;

  v_drawn := public.jl_finalize_game_due_rounds(p_game_type);
  v_opened := public.jl_open_next_game_round(p_game_type);

  return jsonb_build_object(
    'game_type',p_game_type,'locked',v_locked,'drawn',v_drawn,
    'next',v_opened,'processed_at',now()
  );
end;
$$;

create or replace function public.jl_process_game_engine()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_number jsonb; v_pair jsonb;
begin
  v_number := public.jl_process_game('number');
  v_pair := public.jl_process_game('pair');
  return jsonb_build_object('number',v_number,'pair',v_pair,'processed_at',now());
end;
$$;

create or replace function public.jl_finalize_due_rounds()
returns integer
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.jl_finalize_game_due_rounds('number');
end;
$$;

create or replace function public.jl_open_next_scheduled_round()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.jl_open_next_game_round('number');
end;
$$;

create or replace function public.jl_admin_open_game_round(
  p_token text,p_game_type text,p_draw_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round public.game_rounds%rowtype;
  v_settings public.game_settings%rowtype;
begin
  perform public.jl_require_admin(p_token);
  perform public.jl_process_game(p_game_type);
  select * into v_settings from public.game_settings where game_type=p_game_type;
  if v_settings.game_type is null then raise exception 'Jogo inválido.'; end if;
  if not v_settings.enabled then raise exception 'Este jogo está desativado.'; end if;

  if p_draw_at is null
     or p_draw_at <= now() + make_interval(secs => greatest(10,v_settings.lock_seconds+2))
     or p_draw_at > now()+interval '7 days' then
    raise exception 'Defina um sorteio válido entre alguns segundos e 7 dias a partir de agora.';
  end if;

  if exists(
    select 1 from public.game_rounds
    where game_type=p_game_type and status in ('open','locked','closed','drawn')
  ) then
    raise exception 'Finalize a rodada atual deste jogo antes de abrir outra.';
  end if;

  insert into public.game_rounds(game_type,status,closes_at,draw_at)
  values(p_game_type,'open',p_draw_at-make_interval(secs=>v_settings.lock_seconds),p_draw_at)
  returning * into v_round;

  return jsonb_build_object(
    'ok',true,'game_type',p_game_type,'round_no',v_round.round_no,
    'closes_at',v_round.closes_at,'draw_at',v_round.draw_at,
    'message','Rodada aberta para '||case when p_game_type='number' then 'Número Lendário' else 'Dupla Lendária' end||'.'
  );
end;
$$;

create or replace function public.jl_admin_schedule_game_draws(
  p_token text,p_game_type text,p_start_at timestamptz,p_end_at timestamptz,p_interval_minutes integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inserted integer := 0;
  v_requested integer := 0;
begin
  perform public.jl_require_admin(p_token);
  if p_game_type not in ('number','pair') then raise exception 'Jogo inválido.'; end if;
  if p_start_at is null or p_end_at is null then raise exception 'Informe início e fim da programação.'; end if;
  if p_interval_minutes is null or p_interval_minutes < 1 or p_interval_minutes > 1440 then
    raise exception 'O intervalo deve ficar entre 1 e 1440 minutos.';
  end if;
  if p_start_at <= now()+interval '10 seconds' then raise exception 'O primeiro sorteio deve ficar no futuro.'; end if;
  if p_end_at < p_start_at then raise exception 'O fim deve ser igual ou posterior ao início.'; end if;
  if p_end_at > now()+interval '7 days' then raise exception 'A programação pode cobrir no máximo 7 dias.'; end if;

  select count(*) into v_requested
  from generate_series(p_start_at,p_end_at,make_interval(mins=>p_interval_minutes));
  if v_requested > 250 then raise exception 'A programação ultrapassa 250 sorteios por lote.'; end if;

  insert into public.draw_schedule(game_type,draw_at)
  select p_game_type,gs
  from generate_series(p_start_at,p_end_at,make_interval(mins=>p_interval_minutes)) gs
  on conflict (game_type,draw_at) do nothing;
  get diagnostics v_inserted=row_count;

  perform public.jl_process_game(p_game_type);

  return jsonb_build_object(
    'ok',true,'game_type',p_game_type,'requested',v_requested,'inserted',v_inserted,
    'message',v_inserted||' horário(s) programado(s).'
  );
end;
$$;

create or replace function public.jl_admin_add_game_draw_time(
  p_token text,p_game_type text,p_draw_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  perform public.jl_require_admin(p_token);
  if p_game_type not in ('number','pair') then raise exception 'Jogo inválido.'; end if;
  if p_draw_at is null or p_draw_at <= now()+interval '10 seconds' or p_draw_at > now()+interval '7 days' then
    raise exception 'Defina um sorteio entre 10 segundos e 7 dias a partir de agora.';
  end if;

  insert into public.draw_schedule(game_type,draw_at)
  values(p_game_type,p_draw_at)
  on conflict (game_type,draw_at) do nothing
  returning id into v_id;

  if v_id is null then raise exception 'Esse horário já está programado para este jogo.'; end if;
  perform public.jl_process_game(p_game_type);
  return jsonb_build_object('ok',true,'id',v_id,'game_type',p_game_type,'draw_at',p_draw_at,'message','Horário adicionado.');
end;
$$;

create or replace function public.jl_admin_cancel_game_draw_time(
  p_token text,p_game_type text,p_schedule_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_item public.draw_schedule%rowtype;
begin
  perform public.jl_require_admin(p_token);
  select * into v_item from public.draw_schedule
  where id=p_schedule_id and game_type=p_game_type
  for update;
  if v_item.id is null then raise exception 'Horário não encontrado para este jogo.'; end if;
  if v_item.status <> 'pending' then raise exception 'Somente horários futuros podem ser cancelados.'; end if;

  update public.draw_schedule set status='cancelled',updated_at=now() where id=v_item.id;
  return jsonb_build_object('ok',true,'message','Horário cancelado.');
end;
$$;

create or replace function public.jl_admin_clear_game_schedule(
  p_token text,p_game_type text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_count integer:=0;
begin
  perform public.jl_require_admin(p_token);
  if p_game_type not in ('number','pair') then raise exception 'Jogo inválido.'; end if;
  update public.draw_schedule
  set status='cancelled',updated_at=now()
  where game_type=p_game_type and status='pending';
  get diagnostics v_count=row_count;
  return jsonb_build_object('ok',true,'cancelled',v_count,'message',v_count||' horário(s) cancelado(s).');
end;
$$;

create or replace function public.jl_admin_close_game_round(
  p_token text,p_game_type text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_round public.game_rounds%rowtype;
begin
  perform public.jl_require_admin(p_token);
  if p_game_type not in ('number','pair') then raise exception 'Jogo inválido.'; end if;

  select * into v_round
  from public.game_rounds
  where game_type=p_game_type and status in ('open','locked','closed')
  order by opened_at desc limit 1 for update;

  if v_round.id is null then raise exception 'Não há rodada ativa para este jogo.'; end if;

  update public.game_rounds
  set status='locked',closed_at=now(),closes_at=least(closes_at,now()),draw_at=now()
  where id=v_round.id;

  perform public.jl_finalize_game_due_rounds(p_game_type);
  perform public.jl_process_game(p_game_type);

  return jsonb_build_object('ok',true,'game_type',p_game_type,'round_no',v_round.round_no,'message','Rodada encerrada e sorteada.');
end;
$$;

create or replace function public.jl_admin_update_game_settings(
  p_token text,p_game_type text,p_min_bet numeric,p_max_bet numeric,
  p_multiplier numeric,p_lock_seconds integer,p_draw_mode text,p_enabled boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.jl_require_admin(p_token);
  if p_game_type not in ('number','pair') then raise exception 'Jogo inválido.'; end if;

  if exists(
    select 1 from public.game_rounds
    where game_type=p_game_type and status in ('open','locked','closed')
  ) then
    raise exception 'Altere as regras somente quando este jogo não tiver uma rodada ativa.';
  end if;

  if p_min_bet is null or p_min_bet <= 0 or p_max_bet is null or p_max_bet < p_min_bet then
    raise exception 'Limites de aposta inválidos.';
  end if;
  if p_multiplier is null or p_multiplier <= 1 then raise exception 'Multiplicador inválido.'; end if;
  if p_lock_seconds is null or p_lock_seconds < 1 or p_lock_seconds > 60 then raise exception 'Bloqueio deve ficar entre 1 e 60 segundos.'; end if;
  if p_draw_mode not in ('house_min','house_safe_random') then raise exception 'Modo de sorteio inválido.'; end if;

  update public.game_settings
  set min_bet=p_min_bet,max_bet=p_max_bet,multiplier=p_multiplier,
      lock_seconds=p_lock_seconds,draw_mode=p_draw_mode,
      enabled=coalesce(p_enabled,true),updated_at=now()
  where game_type=p_game_type;

  return jsonb_build_object('ok',true,'game_type',p_game_type,'message','Configuração atualizada.');
end;
$$;

create or replace function public.jl_admin_open_round(p_token text,p_closes_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.jl_admin_open_game_round(p_token,'number',p_closes_at);
end;
$$;

create or replace function public.jl_admin_close_round(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.jl_admin_close_game_round(p_token,'number');
end;
$$;

create or replace function public.jl_admin_schedule_draws(
  p_token text,p_start_at timestamptz,p_end_at timestamptz,p_interval_minutes integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.jl_admin_schedule_game_draws(
    p_token,'number',p_start_at,p_end_at,p_interval_minutes
  );
end;
$$;

create or replace function public.jl_admin_add_draw_time(p_token text,p_draw_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.jl_admin_add_game_draw_time(p_token,'number',p_draw_at);
end;
$$;

create or replace function public.jl_admin_cancel_draw_time(p_token text,p_schedule_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.jl_admin_cancel_game_draw_time(p_token,'number',p_schedule_id);
end;
$$;

create or replace function public.jl_admin_clear_draw_schedule(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.jl_admin_clear_game_schedule(p_token,'number');
end;
$$;

create or replace function public.jl_game_public_state(p_game_type text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round public.game_rounds%rowtype;
  v_last public.game_rounds%rowtype;
  v_settings public.game_settings%rowtype;
begin
  select * into v_settings from public.game_settings where game_type=p_game_type;

  select * into v_round
  from public.game_rounds
  where game_type=p_game_type and status in ('open','locked','closed')
  order by opened_at desc limit 1;

  select * into v_last
  from public.game_rounds
  where game_type=p_game_type and status='published'
  order by published_at desc nulls last,opened_at desc limit 1;

  return jsonb_build_object(
    'game_type',p_game_type,
    'settings',jsonb_build_object(
      'min_bet',v_settings.min_bet,'max_bet',v_settings.max_bet,
      'multiplier',v_settings.multiplier,'lock_seconds',v_settings.lock_seconds,
      'draw_mode',v_settings.draw_mode,'enabled',v_settings.enabled
    ),
    'current_round',case when v_round.id is null then null else jsonb_build_object(
      'id',v_round.id,'round_no',v_round.round_no,'status',v_round.status,
      'opened_at',v_round.opened_at,'closes_at',v_round.closes_at,'draw_at',v_round.draw_at
    ) end,
    'last_result',case when v_last.id is null then null else jsonb_build_object(
      'round_no',v_last.round_no,'drawn_number',v_last.drawn_number,
      'pair_drawn_a',v_last.pair_drawn_a,'pair_drawn_b',v_last.pair_drawn_b,
      'drawn_at',v_last.drawn_at,'published_at',v_last.published_at
    ) end
  );
end;
$$;

create or replace function public.jl_public_state()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_number jsonb; v_pair jsonb;
begin
  perform public.jl_process_game_engine();
  v_number := public.jl_game_public_state('number');
  v_pair := public.jl_game_public_state('pair');

  return jsonb_build_object(
    'server_time',now(),
    'games',jsonb_build_object('number',v_number,'pair',v_pair),
    'current_round',v_number->'current_round',
    'last_result',v_number->'last_result'
  );
end;
$$;

create or replace function public.jl_player_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := public.jl_player_id(p_token);
  v_player public.players%rowtype;
  v_public jsonb;
  v_bets jsonb;
  v_pair_bets jsonb;
  v_deposits jsonb;
  v_withdrawals jsonb;
begin
  select * into v_player from public.players where id=v_player_id;
  select public.jl_public_state() into v_public;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_bets
  from (
    select b.id,b.selected_number,b.amount,b.won,b.payout,b.created_at,r.round_no,
      case when r.status='published' then r.drawn_number else null end drawn_number,
      r.status round_status
    from public.bets b join public.game_rounds r on r.id=b.round_id
    where b.player_id=v_player_id
    order by b.created_at desc limit 30
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_pair_bets
  from (
    select pb.id,pb.number_a,pb.number_b,pb.amount,pb.won,pb.payout,pb.created_at,r.round_no,
      case when r.status='published' then r.pair_drawn_a else null end pair_drawn_a,
      case when r.status='published' then r.pair_drawn_b else null end pair_drawn_b,
      r.status round_status
    from public.pair_bets pb join public.game_rounds r on r.id=pb.round_id
    where pb.player_id=v_player_id
    order by pb.created_at desc limit 30
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_deposits
  from (select id,amount,note,status,created_at,reviewed_at from public.deposit_requests where player_id=v_player_id order by created_at desc limit 20) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_withdrawals
  from (select id,amount,status,reason,created_at,reviewed_at from public.withdrawal_requests where player_id=v_player_id order by created_at desc limit 20) x;

  return v_public || jsonb_build_object(
    'player',jsonb_build_object('id',v_player.id,'name',v_player.name,'phone',v_player.phone,'balance',v_player.balance,'blocked',v_player.blocked),
    'bets',v_bets,'pair_bets',v_pair_bets,'deposits',v_deposits,'withdrawals',v_withdrawals
  );
end;
$$;

create or replace function public.jl_admin_game_snapshot(p_game_type text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round public.game_rounds%rowtype;
  v_last public.game_rounds%rowtype;
  v_settings public.game_settings%rowtype;
  v_schedule jsonb;
  v_stats jsonb;
  v_recent jsonb;
begin
  select * into v_settings from public.game_settings where game_type=p_game_type;
  select * into v_round from public.game_rounds
    where game_type=p_game_type and status in ('open','locked','closed')
    order by opened_at desc limit 1;
  select * into v_last from public.game_rounds
    where game_type=p_game_type and status='published'
    order by published_at desc nulls last,opened_at desc limit 1;

  select coalesce(jsonb_agg(x order by x.draw_at),'[]'::jsonb) into v_schedule
  from (
    select id,draw_at,status,round_id,created_at
    from public.draw_schedule
    where game_type=p_game_type and status in ('pending','active')
    order by draw_at limit 250
  ) x;

  if p_game_type='number' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'number',n,'bets',coalesce(s.bet_count,0),'total',coalesce(s.total,0)
    ) order by n),'[]'::jsonb) into v_stats
    from generate_series(0,10) n
    left join (
      select selected_number,count(*)::int bet_count,sum(amount)::numeric total
      from public.bets where round_id=v_round.id group by selected_number
    ) s on s.selected_number=n;

    select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_recent
    from (
      select b.id,b.selected_number,b.amount,b.won,b.payout,b.created_at,p.name,p.phone,r.round_no
      from public.bets b join public.players p on p.id=b.player_id join public.game_rounds r on r.id=b.round_id
      order by b.created_at desc limit 100
    ) x;
  else
    select coalesce(jsonb_agg(jsonb_build_object(
      'number_a',c.a,'number_b',c.b,'bets',coalesce(s.bet_count,0),'total',coalesce(s.total,0)
    ) order by c.a,c.b),'[]'::jsonb) into v_stats
    from (
      select a,b from generate_series(1,10) a cross join generate_series(1,10) b where a<b
    ) c
    left join (
      select number_a,number_b,count(*)::int bet_count,sum(amount)::numeric total
      from public.pair_bets where round_id=v_round.id group by number_a,number_b
    ) s on s.number_a=c.a and s.number_b=c.b;

    select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_recent
    from (
      select pb.id,pb.number_a,pb.number_b,pb.amount,pb.won,pb.payout,pb.created_at,p.name,p.phone,r.round_no
      from public.pair_bets pb join public.players p on p.id=pb.player_id join public.game_rounds r on r.id=pb.round_id
      order by pb.created_at desc limit 100
    ) x;
  end if;

  return jsonb_build_object(
    'game_type',p_game_type,
    'settings',to_jsonb(v_settings),
    'round',case when v_round.id is null then null else jsonb_build_object(
      'id',v_round.id,'round_no',v_round.round_no,'status',v_round.status,
      'opened_at',v_round.opened_at,'closes_at',v_round.closes_at,
      'draw_at',v_round.draw_at,'schedule_id',v_round.schedule_id
    ) end,
    'last_result',case when v_last.id is null then null else jsonb_build_object(
      'round_no',v_last.round_no,'drawn_number',v_last.drawn_number,
      'pair_drawn_a',v_last.pair_drawn_a,'pair_drawn_b',v_last.pair_drawn_b,
      'drawn_at',v_last.drawn_at,'published_at',v_last.published_at
    ) end,
    'stats',v_stats,'schedule',v_schedule,'recent_bets',v_recent
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
  v_number jsonb;
  v_pair jsonb;
  v_deposits jsonb;
  v_withdrawals jsonb;
  v_players jsonb;
begin
  perform public.jl_require_admin(p_token);
  perform public.jl_process_game_engine();

  v_number := public.jl_admin_game_snapshot('number');
  v_pair := public.jl_admin_game_snapshot('pair');

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_deposits
  from (
    select d.id,d.amount,d.note,d.status,d.created_at,p.name,p.phone
    from public.deposit_requests d join public.players p on p.id=d.player_id
    where d.status='pending' order by d.created_at desc limit 100
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_withdrawals
  from (
    select w.id,w.amount,w.status,w.reason,w.created_at,p.name,p.phone
    from public.withdrawal_requests w join public.players p on p.id=w.player_id
    where w.status='pending' order by w.created_at desc limit 100
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_players
  from (
    select id,name,phone,balance,blocked,created_at
    from public.players order by created_at desc limit 200
  ) x;

  return jsonb_build_object(
    'server_time',now(),
    'games',jsonb_build_object('number',v_number,'pair',v_pair),
    'pending_deposits',v_deposits,
    'pending_withdrawals',v_withdrawals,
    'players',v_players
  );
end;
$$;

revoke execute on function public.jl_random_index(integer) from public;
revoke execute on function public.jl_secure_number(uuid) from public;
revoke execute on function public.jl_secure_number() from public;
revoke execute on function public.jl_secure_pair(uuid) from public;
revoke execute on function public.jl_open_next_game_round(text) from public;
revoke execute on function public.jl_finalize_game_due_rounds(text) from public;
revoke execute on function public.jl_process_game(text) from public;
revoke execute on function public.jl_admin_game_snapshot(text) from public;

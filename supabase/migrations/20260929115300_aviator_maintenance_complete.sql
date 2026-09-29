-- Aviator: completar o interruptor de manutencao no banco.
-- Objetivos:
-- 1. Estado publico/admin inclui enabled + mensagem.
-- 2. Desligar o Aviator impede novas apostas e novas rodadas.
-- 3. Rodadas OPEN ja existentes podem terminar normalmente; LOCKED/FLYING nunca sao abortadas.
-- 4. Reativar volta a permitir a abertura da proxima rodada.
-- 5. Toggle e aposta sao serializados para evitar uma aposta entrar depois do fecho administrativo.

create table if not exists public.jl_aviator_settings(
  id boolean primary key default true check(id),
  enabled boolean not null default true,
  maintenance_message text not null default 'Aviator em manutencao. Volte em breve.',
  updated_at timestamptz not null default now()
);

insert into public.jl_aviator_settings(id)
values(true)
on conflict(id) do nothing;

alter table public.jl_aviator_settings enable row level security;
revoke all on public.jl_aviator_settings from public,anon,authenticated;

create or replace function public.jl_aviator_public_state()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  r public.jl_aviator_rounds;
  s public.jl_aviator_settings;
  v_active int:=0;
  v_total numeric:=0;
begin
  select * into s from public.jl_aviator_settings where id=true;
  select * into r from public.jl_aviator_rounds order by id desc limit 1;

  if r.id is null then
    return jsonb_build_object(
      'server_time',now(),
      'enabled',coalesce(s.enabled,true),
      'maintenance_message',coalesce(s.maintenance_message,'Aviator em manutencao. Volte em breve.'),
      'round',null
    );
  end if;

  select count(*),coalesce(sum(stake),0)
    into v_active,v_total
  from public.jl_aviator_bets
  where round_id=r.id and status='ACTIVE';

  return jsonb_build_object(
    'server_time',now(),
    'enabled',coalesce(s.enabled,true),
    'maintenance_message',coalesce(s.maintenance_message,'Aviator em manutencao. Volte em breve.'),
    'round',jsonb_build_object(
      'id',r.id,
      'status',r.status,
      'opened_at',r.opened_at,
      'betting_closes_at',r.betting_closes_at,
      'started_at',r.started_at,
      'crashed_at',r.crashed_at,
      'crash_multiplier',r.crash_multiplier,
      'active_bets',v_active,
      'total_staked',v_total,
      'visual_extension',r.visual_extension,
      'visual_seed_commit',r.visual_seed_commit,
      'visual_seed_reveal',case when r.status in ('CRASHED','SETTLED') then r.visual_seed_reveal else null end
    )
  );
end
$$;

revoke all on function public.jl_aviator_public_state() from public;
grant execute on function public.jl_aviator_public_state() to anon,authenticated;

create or replace function public.jl_aviator_admin_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  b public.jl_aviator_bank;
  r public.jl_aviator_rounds;
  s public.jl_aviator_settings;
  v_bets int:=0;
  v_staked numeric:=0;
  v_paid numeric:=0;
begin
  perform public.jl_require_admin(p_token);

  select * into b from public.jl_aviator_bank where id=true;
  select * into s from public.jl_aviator_settings where id=true;
  select * into r from public.jl_aviator_rounds order by id desc limit 1;

  if r.id is not null then
    select count(*),coalesce(sum(stake),0),coalesce(sum(payout),0)
      into v_bets,v_staked,v_paid
    from public.jl_aviator_bets
    where round_id=r.id;
  end if;

  return jsonb_build_object(
    'enabled',coalesce(s.enabled,true),
    'maintenance_message',coalesce(s.maintenance_message,'Aviator em manutencao. Volte em breve.'),
    'bank',jsonb_build_object(
      'balance',coalesce(b.balance,0),
      'exposure_ratio',coalesce(b.exposure_ratio,0.5)
    ),
    'round',case when r.id is null then null else jsonb_build_object(
      'id',r.id,
      'status',r.status,
      'total_staked',r.total_staked,
      'risk_reserve',r.risk_reserve,
      'financial_ceiling',r.financial_ceiling,
      'crash_multiplier',r.crash_multiplier,
      'visual_extension',r.visual_extension,
      'opened_at',r.opened_at,
      'started_at',r.started_at
    ) end,
    'bets',v_bets,
    'stake_sum',v_staked,
    'paid_sum',v_paid
  );
end
$$;

revoke all on function public.jl_aviator_admin_state(text) from public;
grant execute on function public.jl_aviator_admin_state(text) to anon,authenticated;

create or replace function public.jl_aviator_admin_set_enabled(
  p_token text,
  p_enabled boolean
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  s public.jl_aviator_settings;
begin
  perform public.jl_require_admin(p_token);
  if p_enabled is null then
    raise exception 'Estado de manutencao invalido.';
  end if;

  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));

  insert into public.jl_aviator_settings(id,enabled,updated_at)
  values(true,p_enabled,now())
  on conflict(id) do update
    set enabled=excluded.enabled,
        updated_at=excluded.updated_at
  returning * into s;

  insert into public.audit_log(action,details)
  values(
    'aviator.maintenance_changed',
    jsonb_build_object('enabled',s.enabled,'updatedAt',s.updated_at)
  );

  return jsonb_build_object(
    'ok',true,
    'enabled',s.enabled,
    'maintenance_message',s.maintenance_message
  );
end
$$;

revoke all on function public.jl_aviator_admin_set_enabled(text,boolean) from public;
grant execute on function public.jl_aviator_admin_set_enabled(text,boolean) to anon,authenticated;

create or replace function public.jl_aviator_place_bet(
  p_token text,
  p_amount numeric,
  p_request_key text
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_player public.players;
  v_round public.jl_aviator_rounds;
  v_bet public.jl_aviator_bets;
  v_enabled boolean;
begin
  if p_request_key is null or length(trim(p_request_key))<8 or length(p_request_key)>100 then
    raise exception 'Chave da aposta invalida.';
  end if;

  -- Evita corrida entre retries iguais e entre aposta/toggle de manutencao.
  perform pg_advisory_xact_lock(hashtext('jl_aviator_bet_'||v_player_id::text||'_'||trim(p_request_key)));
  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));

  select * into v_bet
  from public.jl_aviator_bets
  where player_id=v_player_id and request_key=p_request_key;

  if v_bet.id is not null then
    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'bet_id',v_bet.id,
      'round_id',v_bet.round_id,
      'stake',v_bet.stake
    );
  end if;

  select enabled into v_enabled
  from public.jl_aviator_settings
  where id=true;

  if coalesce(v_enabled,true)=false then
    raise exception 'Aviator em manutencao. Volte em breve.';
  end if;

  if p_amount is null or p_amount<1 or p_amount>1000000 then
    raise exception 'Valor de aposta invalido.';
  end if;

  select * into v_round
  from public.jl_aviator_rounds
  where status='OPEN'
    and (betting_closes_at is null or betting_closes_at>clock_timestamp())
  order by id desc
  limit 1
  for update;

  if v_round.id is null then
    raise exception 'Nao ha rodada Aviator aberta.';
  end if;

  select * into v_player
  from public.players
  where id=v_player_id
  for update;

  if v_player.blocked then
    raise exception 'Jogador bloqueado.';
  end if;

  if v_player.balance<p_amount then
    raise exception 'Saldo insuficiente.';
  end if;

  update public.players
  set balance=round(balance-p_amount,2),updated_at=now()
  where id=v_player_id;

  insert into public.jl_aviator_bets(round_id,player_id,stake,request_key)
  values(v_round.id,v_player_id,round(p_amount,2),p_request_key)
  returning * into v_bet;

  insert into public.transactions(player_id,kind,amount,status,note)
  values(
    v_player_id,
    'aviator_bet',
    -round(p_amount,2),
    'completed',
    'Aposta Aviator rodada '||v_round.id
  );

  insert into public.audit_log(action,details)
  values(
    'aviator.bet_placed',
    jsonb_build_object(
      'roundId',v_round.id,
      'betId',v_bet.id,
      'playerId',v_player_id,
      'stake',v_bet.stake
    )
  );

  return jsonb_build_object(
    'ok',true,
    'already_processed',false,
    'bet_id',v_bet.id,
    'round_id',v_round.id,
    'stake',v_bet.stake,
    'balance',v_player.balance-round(p_amount,2)
  );
end
$$;

revoke all on function public.jl_aviator_place_bet(text,numeric,text) from public;
grant execute on function public.jl_aviator_place_bet(text,numeric,text) to anon,authenticated;

create or replace function public.jl_aviator_open_next_if_due()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  r public.jl_aviator_rounds;
  v_enabled boolean;
begin
  perform pg_advisory_xact_lock(hashtext('jl_aviator_engine_tick'));
  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));

  select enabled into v_enabled
  from public.jl_aviator_settings
  where id=true;

  if coalesce(v_enabled,true)=false then
    return jsonb_build_object('opened',false,'maintenance',true);
  end if;

  if exists(
    select 1
    from public.jl_aviator_rounds
    where status in ('OPEN','LOCKED','FLYING')
  ) then
    return jsonb_build_object('opened',false);
  end if;

  select * into r
  from public.jl_aviator_rounds
  order by id desc
  limit 1;

  if r.id is null
     or (r.status='SETTLED' and coalesce(r.next_round_at,now())<=now()) then
    insert into public.jl_aviator_rounds(status,betting_closes_at)
    values('OPEN',now()+interval '12 seconds')
    returning * into r;

    return jsonb_build_object('opened',true,'round_id',r.id);
  end if;

  return jsonb_build_object('opened',false);
end
$$;

revoke all on function public.jl_aviator_open_next_if_due() from public,anon,authenticated;
grant execute on function public.jl_aviator_open_next_if_due() to service_role;

create or replace function public.jl_process_game_engine_tick()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_need_work boolean:=false;
  v_aviator_need boolean:=false;
  v_aviator_enabled boolean:=true;
  v_main jsonb;
  v_aviator jsonb;
begin
  select exists(
    select 1
    from public.game_rounds
    where status in ('open','locked','closed')
      and ((status='open' and closes_at<=now()) or draw_at<=now())
  )
  or exists(
    select 1
    from public.draw_schedule ds
    join public.game_settings gs
      on gs.game_type=ds.game_type and gs.enabled
    where ds.status='pending'
      and not exists(
        select 1
        from public.game_rounds gr
        where gr.game_type=ds.game_type
          and gr.status in ('open','locked','closed','drawn')
      )
  )
  into v_need_work;

  select coalesce(enabled,true)
    into v_aviator_enabled
  from public.jl_aviator_settings
  where id=true;

  select
    exists(
      select 1
      from public.jl_aviator_rounds
      where (status='OPEN' and betting_closes_at<=now())
         or status='FLYING'
    )
    or (
      v_aviator_enabled
      and (
        exists(
          select 1
          from public.jl_aviator_rounds
          where status='SETTLED'
            and coalesce(next_round_at,now())<=now()
        )
        or not exists(select 1 from public.jl_aviator_rounds)
      )
    )
  into v_aviator_need;

  if v_need_work then
    v_main:=public.jl_process_game_engine();
  else
    v_main:=jsonb_build_object('idle',true);
  end if;

  if v_aviator_need then
    v_aviator:=public.jl_aviator_engine_tick();
  else
    v_aviator:=jsonb_build_object(
      'idle',true,
      'maintenance',not v_aviator_enabled
    );
  end if;

  return jsonb_build_object(
    'main',v_main,
    'aviator',v_aviator,
    'processed_at',now()
  );
end
$$;

revoke all on function public.jl_process_game_engine_tick() from public,anon,authenticated;
grant execute on function public.jl_process_game_engine_tick() to service_role;

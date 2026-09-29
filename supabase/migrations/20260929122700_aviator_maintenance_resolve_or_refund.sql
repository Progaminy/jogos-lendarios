-- Aviator: manutenção nunca deixa aposta ACTIVE presa.
-- OPEN/LOCKED => cancelar e reembolsar atomicamente.
-- FLYING => terminar pelo motor normal.
-- CRASHED => concluir SETTLED no próximo/mesmo tick.

alter table public.jl_aviator_bets
  add column if not exists refunded_at timestamptz,
  add column if not exists refund_transaction_id uuid;

do $$
begin
  if not exists(
    select 1
    from pg_constraint
    where conrelid='public.jl_aviator_bets'::regclass
      and conname='jl_aviator_bets_refund_transaction_fkey'
  ) then
    alter table public.jl_aviator_bets
      add constraint jl_aviator_bets_refund_transaction_fkey
      foreign key(refund_transaction_id)
      references public.transactions(id)
      on delete restrict;
  end if;
end
$$;

alter table public.jl_aviator_bets
  drop constraint if exists jl_aviator_bets_refund_fields_check;

alter table public.jl_aviator_bets
  add constraint jl_aviator_bets_refund_fields_check
  check(
    status<>'REFUNDED'
    or (
      payout=stake
      and refunded_at is not null
      and refund_transaction_id is not null
      and cashout_multiplier is null
      and cashed_out_at is null
      and payout_transaction_id is null
      and cashout_source is null
    )
  );

alter table public.transactions
  drop constraint if exists transactions_kind_check;

alter table public.transactions
  add constraint transactions_kind_check
  check(
    kind=any(array[
      'deposit'::text,
      'withdrawal'::text,
      'withdrawal_refund'::text,
      'bet'::text,
      'payout'::text,
      'adjustment'::text,
      'ludo_stake'::text,
      'ludo_reentry'::text,
      'ludo_refund'::text,
      'ludo_payout'::text,
      'aviator_bet'::text,
      'aviator_payout'::text,
      'aviator_refund'::text
    ])
  );

create or replace function public.jl_aviator_refund_preflight_round(
  p_round_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  v_round public.jl_aviator_rounds;
  v_bet public.jl_aviator_bets;
  v_tx uuid;
  v_count integer:=0;
  v_total numeric:=0;
  v_now timestamptz:=clock_timestamp();
begin
  select *
    into v_round
  from public.jl_aviator_rounds
  where id=p_round_id
  for update;

  if v_round.id is null then
    return jsonb_build_object(
      'ok',true,
      'round_id',p_round_id,
      'refunded_bets',0,
      'refunded_total',0,
      'already_resolved',true
    );
  end if;

  if v_round.status not in ('OPEN','LOCKED') then
    return jsonb_build_object(
      'ok',true,
      'round_id',v_round.id,
      'status',v_round.status,
      'refunded_bets',0,
      'refunded_total',0,
      'already_resolved',true
    );
  end if;

  for v_bet in
    select *
    from public.jl_aviator_bets
    where round_id=v_round.id
      and status='ACTIVE'
    order by id
    for update
  loop
    insert into public.transactions(
      player_id,
      kind,
      amount,
      status,
      note
    )
    values(
      v_bet.player_id,
      'aviator_refund',
      v_bet.stake,
      'completed',
      'Reembolso Aviator manutenção · rodada '||
        v_round.id||' · aposta '||v_bet.id
    )
    returning id into v_tx;

    update public.players
       set balance=round(balance+v_bet.stake,2),
           updated_at=v_now
     where id=v_bet.player_id;

    update public.jl_aviator_bets
       set status='REFUNDED',
           payout=v_bet.stake,
           refunded_at=v_now,
           refund_transaction_id=v_tx
     where id=v_bet.id
       and status='ACTIVE';

    v_count:=v_count+1;
    v_total:=v_total+v_bet.stake;
  end loop;

  update public.jl_aviator_rounds
     set status='CANCELLED',
         settled_at=coalesce(settled_at,v_now),
         next_round_at=null
   where id=v_round.id
     and status in ('OPEN','LOCKED');

  insert into public.audit_log(action,details)
  values(
    'aviator.maintenance_preflight_refunded',
    jsonb_build_object(
      'roundId',v_round.id,
      'previousStatus',v_round.status,
      'refundedBets',v_count,
      'refundedTotal',v_total,
      'resolvedAt',v_now
    )
  );

  return jsonb_build_object(
    'ok',true,
    'round_id',v_round.id,
    'previous_status',v_round.status,
    'status','CANCELLED',
    'refunded_bets',v_count,
    'refunded_total',v_total,
    'already_resolved',false
  );
end
$$;

revoke all on function public.jl_aviator_refund_preflight_round(bigint)
from public,anon,authenticated;
grant execute on function public.jl_aviator_refund_preflight_round(bigint)
to service_role;

create or replace function public.jl_aviator_engine_tick()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  r public.jl_aviator_rounds;
  result jsonb;
  v_enabled boolean:=true;
  v_active int:=0;
  v_one_round_test boolean:=false;
  v_now timestamptz:=clock_timestamp();
  v_takeoff_at timestamptz;
  v_seconds_to_takeoff integer;
begin
  perform pg_advisory_xact_lock(hashtext('jl_aviator_engine_tick'));
  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));

  select coalesce(enabled,true),coalesce(one_round_test,false)
    into v_enabled,v_one_round_test
  from public.jl_aviator_settings
  where id=true;

  select *
    into r
  from public.jl_aviator_rounds
  where status in ('OPEN','LOCKED','FLYING','CRASHED')
  order by id desc
  limit 1
  for update;

  if r.id is null then
    if not v_enabled then
      return jsonb_build_object('action','WAIT','maintenance',true);
    end if;
    return public.jl_aviator_open_next_if_due();
  end if;

  -- Manutenção antes da descolagem: não iniciar voo novo.
  -- Reembolsar toda aposta ACTIVE e cancelar a rodada atomicamente.
  if not v_enabled and r.status in ('OPEN','LOCKED') then
    result:=public.jl_aviator_refund_preflight_round(r.id);

    return result || jsonb_build_object(
      'action','CANCELLED_REFUNDED',
      'phase','CANCELLED',
      'maintenance',true,
      'one_round_test',false
    );
  end if;

  if r.status='OPEN' then
    select count(*)
      into v_active
    from public.jl_aviator_bets
    where round_id=r.id
      and status='ACTIVE';

    if r.betting_closes_at is not null
       and v_now>=r.betting_closes_at then
      perform public.jl_aviator_lock_round(r.id);

      return jsonb_build_object(
        'action','LOCKED',
        'round_id',r.id,
        'status','LOCKED',
        'phase','LOCKED',
        'takeoff_at',coalesce(r.takeoff_at,v_now+interval '3 seconds'),
        'maintenance',false,
        'one_round_test',v_one_round_test
      );
    end if;

    return jsonb_build_object(
      'action','WAIT',
      'round_id',r.id,
      'status',r.status,
      'phase','BETTING',
      'maintenance',false,
      'one_round_test',v_one_round_test
    );
  end if;

  if r.status='LOCKED' then
    v_takeoff_at:=coalesce(
      r.takeoff_at,
      r.locked_at+interval '3 seconds',
      v_now
    );

    if v_now<v_takeoff_at then
      v_seconds_to_takeoff:=greatest(
        0,
        ceil(extract(epoch from (v_takeoff_at-v_now)))
      )::integer;

      return jsonb_build_object(
        'action','WAIT_LOCKED',
        'round_id',r.id,
        'status','LOCKED',
        'phase','LOCKED',
        'seconds_to_takeoff',v_seconds_to_takeoff,
        'takeoff_at',v_takeoff_at,
        'maintenance',false,
        'one_round_test',v_one_round_test
      );
    end if;

    r:=public.jl_aviator_start_round(r.id);

    return jsonb_build_object(
      'action','STARTED',
      'round_id',r.id,
      'status','FLYING',
      'phase','FLYING',
      'started_at',r.started_at,
      'maintenance',false,
      'one_round_test',v_one_round_test
    );
  end if;

  -- Já descolou: nunca reembolsar arbitrariamente.
  -- O motor financeiro normal decide cash-out/crash/liquidação.
  if r.status='FLYING' then
    result:=public.jl_aviator_tick(r.id);

    if result->>'status'='CRASHED' then
      perform public.jl_aviator_publish_proof(r.id);

      return result || jsonb_build_object(
        'action','CRASHED',
        'phase','CRASHED',
        'maintenance',v_one_round_test or not v_enabled,
        'one_round_test',v_one_round_test
      );
    end if;

    return result || jsonb_build_object(
      'maintenance',v_one_round_test or not v_enabled
    );
  end if;

  if r.status='CRASHED' then
    perform public.jl_aviator_publish_proof(r.id);

    update public.jl_aviator_rounds
       set status='SETTLED',
           settled_at=coalesce(settled_at,now()),
           next_round_at=coalesce(next_round_at,now()+interval '4 seconds')
     where id=r.id
     returning * into r;

    if v_one_round_test then
      update public.jl_aviator_settings
         set enabled=false,
             one_round_test=false,
             updated_at=clock_timestamp()
       where id=true;

      insert into public.audit_log(action,details)
      values(
        'aviator.one_round_test_finished',
        jsonb_build_object('roundId',r.id,'finishedAt',clock_timestamp())
      );
    end if;

    return jsonb_build_object(
      'action','SETTLED',
      'round_id',r.id,
      'status',r.status,
      'phase','SETTLED',
      'maintenance',v_one_round_test or not v_enabled,
      'auto_maintenance',v_one_round_test,
      'one_round_test',false
    );
  end if;

  return jsonb_build_object(
    'action','WAIT',
    'round_id',r.id,
    'status',r.status,
    'phase',case when r.status='OPEN' then 'BETTING' else r.status end,
    'maintenance',not v_enabled,
    'one_round_test',v_one_round_test
  );
end
$$;

revoke all on function public.jl_aviator_engine_tick()
from public,anon,authenticated;
grant execute on function public.jl_aviator_engine_tick()
to service_role;

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
  v_admin uuid:=public.jl_admin_account_id(p_token);
  v_resolution jsonb:=jsonb_build_object('action','NONE');
begin
  if v_admin is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  if p_enabled is null then
    raise exception 'Estado de manutencao invalido.';
  end if;

  -- Mesma ordem do motor: engine -> maintenance.
  perform pg_advisory_xact_lock(hashtext('jl_aviator_engine_tick'));
  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));

  insert into public.jl_aviator_settings(
    id,enabled,one_round_test,maintenance_message,updated_at
  )
  values(
    true,p_enabled,false,'Aviator brevemente.',clock_timestamp()
  )
  on conflict(id) do update
    set enabled=excluded.enabled,
        one_round_test=false,
        maintenance_message='Aviator brevemente.',
        updated_at=excluded.updated_at
  returning * into s;

  if not p_enabled then
    -- Resolve imediatamente OPEN/LOCKED, avança FLYING uma vez
    -- e conclui CRASHED. O cron continua FLYING até terminar.
    v_resolution:=public.jl_aviator_engine_tick();
  end if;

  insert into public.audit_log(action,details)
  values(
    'aviator.maintenance_changed',
    jsonb_build_object(
      'enabled',s.enabled,
      'updatedAt',s.updated_at,
      'oneRoundTest',false,
      'resolution',v_resolution,
      'admin_id',v_admin,
      'admin_session_id',nullif(current_setting('jl.admin_session_id',true),''),
      'admin_name',nullif(current_setting('jl.admin_name',true),''),
      'admin_role',nullif(current_setting('jl.admin_role',true),'')
    )
  );

  return jsonb_build_object(
    'ok',true,
    'enabled',s.enabled,
    'one_round_test',false,
    'maintenance_message','Aviator brevemente.',
    'resolution',v_resolution
  );
end
$$;

revoke all on function public.jl_aviator_admin_set_enabled(text,boolean)
from public;
grant execute on function public.jl_aviator_admin_set_enabled(text,boolean)
to anon,authenticated;

-- Reabrir também segue ordem de locks engine -> maintenance.
create or replace function public.jl_aviator_admin_reopen(p_token text)
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare
  v_state jsonb;
  v_round jsonb;
  v_status text;
begin
  perform pg_advisory_xact_lock(hashtext('jl_aviator_engine_tick'));
  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));

  v_state:=public.jl_aviator_admin_state(p_token);

  if coalesce((v_state->>'enabled')::boolean,false) then
    return jsonb_build_object(
      'ok',true,
      'enabled',true,
      'already_open',true,
      'maintenance_message','Aviator brevemente.'
    );
  end if;

  v_round:=v_state->'round';
  v_status:=v_round->>'status';

  if coalesce(v_status in ('OPEN','LOCKED','FLYING','CRASHED'),false) then
    raise exception 'Aguarde a rodada atual terminar antes de reabrir o Aviator.';
  end if;

  perform public.jl_aviator_admin_set_enabled(p_token,true);

  return jsonb_build_object(
    'ok',true,
    'enabled',true,
    'already_open',false,
    'maintenance_message','Aviator brevemente.',
    'ready_for_new_rounds',true
  );
end
$$;

revoke all on function public.jl_aviator_admin_reopen(text)
from public;
grant execute on function public.jl_aviator_admin_reopen(text)
to anon,authenticated,service_role;

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
      where
        (
          not v_aviator_enabled
          and status in ('OPEN','LOCKED','FLYING','CRASHED')
        )
        or (status='OPEN' and betting_closes_at<=now())
        or status in ('LOCKED','FLYING','CRASHED')
    )
    or (
      v_aviator_enabled
      and (
        not exists(select 1 from public.jl_aviator_rounds)
        or exists(
          select 1
          from (
            select status,next_round_at
            from public.jl_aviator_rounds
            order by id desc
            limit 1
          ) latest
          where latest.status='CANCELLED'
             or (
               latest.status='SETTLED'
               and coalesce(latest.next_round_at,now())<=now()
             )
        )
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

revoke all on function public.jl_process_game_engine_tick()
from public,anon,authenticated;
grant execute on function public.jl_process_game_engine_tick()
to service_role;

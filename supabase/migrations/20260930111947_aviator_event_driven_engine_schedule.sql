alter table public.jl_aviator_rounds
  add column if not exists engine_due_at timestamptz;

create index if not exists jl_aviator_rounds_engine_due_idx
on public.jl_aviator_rounds(engine_due_at,id)
where status in ('OPEN','LOCKED','FLYING','CRASHED');

create index if not exists jl_aviator_bets_active_auto_due_idx
on public.jl_aviator_bets(round_id,auto_cashout_multiplier,id)
where status='ACTIVE' and auto_cashout_multiplier is not null;

create or replace function public.jl_aviator_multiplier_reach_at(
  p_started_at timestamptz,
  p_multiplier numeric
)
returns timestamptz
language sql
immutable
set search_path to 'pg_catalog','public'
as $function$
  select case
    when p_started_at is null or p_multiplier is null or p_multiplier<=1
      then p_started_at
    else p_started_at
      + (ln(p_multiplier::numeric)/ln(1.06::numeric))*interval '1 second'
  end;
$function$;

revoke all on function public.jl_aviator_multiplier_reach_at(timestamptz,numeric)
from public,anon,authenticated;
grant execute on function public.jl_aviator_multiplier_reach_at(timestamptz,numeric)
to service_role;

create or replace function public.jl_aviator_schedule_next_engine_event(
  p_round_id bigint
)
returns timestamptz
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_round public.jl_aviator_rounds;
  v_target numeric;
  v_auto numeric;
  v_next_multiplier numeric;
  v_due timestamptz;
begin
  select *
    into v_round
  from public.jl_aviator_rounds
  where id=p_round_id
  for update;

  if v_round.id is null then
    return null;
  end if;

  case v_round.status
    when 'OPEN' then
      v_due:=v_round.betting_closes_at;
    when 'LOCKED' then
      v_due:=coalesce(
        v_round.takeoff_at,
        v_round.locked_at+interval '3 seconds',
        clock_timestamp()
      );
    when 'FLYING' then
      v_target:=coalesce(
        v_round.effective_target,
        v_round.financial_ceiling,
        v_round.visual_target
      );

      if v_round.started_at is null or v_target is null then
        v_due:=clock_timestamp();
      else
        select min(b.auto_cashout_multiplier)
          into v_auto
        from public.jl_aviator_bets b
        where b.round_id=p_round_id
          and b.status='ACTIVE'
          and b.auto_cashout_multiplier is not null
          and b.auto_cashout_multiplier<v_target;

        v_next_multiplier:=case
          when v_auto is null then v_target
          else least(v_auto,v_target)
        end;

        v_due:=public.jl_aviator_multiplier_reach_at(
          v_round.started_at,
          v_next_multiplier
        );
      end if;
    when 'CRASHED' then
      v_due:=clock_timestamp();
    else
      v_due:=null;
  end case;

  update public.jl_aviator_rounds
     set engine_due_at=v_due
   where id=p_round_id;

  return v_due;
end;
$function$;

revoke all on function public.jl_aviator_schedule_next_engine_event(bigint)
from public,anon,authenticated;
grant execute on function public.jl_aviator_schedule_next_engine_event(bigint)
to service_role;;

CREATE OR REPLACE FUNCTION public.jl_aviator_lock_round(p_round_id bigint)
 RETURNS jl_aviator_rounds
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_round public.jl_aviator_rounds;
  v_bank public.jl_aviator_bank;
  v_total numeric;
  v_seed text;
  v_commit text;
  v_visual numeric;
  v_financial numeric;
  v_locked_effective numeric;
  v_payload text;
  v_lock_commit text;
begin
  select *
    into v_round
  from public.jl_aviator_rounds
  where id=p_round_id
  for update;

  if not found or v_round.status<>'OPEN' then
    raise exception 'Rodada nao esta OPEN';
  end if;

  if v_round.round_seed_commit is null
     or not exists(
       select 1 from public.jl_aviator_round_secrets
       where round_id=p_round_id
     ) then
    perform public.jl_aviator_prepare_fairness(p_round_id);

    select *
      into v_round
    from public.jl_aviator_rounds
    where id=p_round_id;
  end if;

  select seed
    into v_seed
  from public.jl_aviator_round_secrets
  where round_id=p_round_id;

  v_commit:=encode(extensions.digest(v_seed,'sha256'),'hex');

  if v_round.round_seed_commit<>v_commit then
    raise exception 'Seed nao corresponde ao compromisso pre-aposta';
  end if;

  v_visual:=public.jl_aviator_fairness_visual_target(v_commit);

  select *
    into v_bank
  from public.jl_aviator_bank
  where id=true
  for update;

  select coalesce(sum(stake),0)
    into v_total
  from public.jl_aviator_bets
  where round_id=p_round_id
    and status='ACTIVE';

  v_financial:=public.jl_aviator_financial_ceiling(
    v_bank.balance,
    v_total,
    v_bank.exposure_ratio
  );

  v_locked_effective:=case
    when v_total=0 then v_visual
    else v_financial
  end;

  v_payload:=public.jl_aviator_fairness_lock_payload(
    p_round_id,
    v_commit,
    v_total,
    v_financial,
    v_visual,
    v_locked_effective
  );

  v_lock_commit:=encode(extensions.digest(v_payload,'sha256'),'hex');

  update public.jl_aviator_rounds
     set status='LOCKED',
         engine_due_at=coalesce(v_round.takeoff_at,clock_timestamp()+interval '3 seconds'),
         locked_at=clock_timestamp(),
         bank_balance_snapshot=v_bank.balance,
         exposure_ratio_snapshot=v_bank.exposure_ratio,
         risk_reserve=round(v_bank.balance*v_bank.exposure_ratio,2),
         total_staked=v_total,
         financial_ceiling=v_financial,
         visual_target=v_visual,
         round_seed_commit=v_commit,
         visual_seed_commit=v_commit,
         lock_proof_commit=v_lock_commit,
         locked_effective_target=v_locked_effective,
         effective_target=v_locked_effective,
         round_seed_reveal=null,
         visual_seed_reveal=null,
         visual_extension=(v_total=0),
         fairness_version='JL-AVIATOR-PF-v2'
   where id=p_round_id
  returning * into v_round;

  perform public.jl_aviator_schedule_next_engine_event(p_round_id);
  select * into v_round from public.jl_aviator_rounds where id=p_round_id;
  return v_round;
end
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_start_round(p_round_id bigint)
 RETURNS jl_aviator_rounds
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v public.jl_aviator_rounds;
  v_takeoff_at timestamptz;
  v_now timestamptz:=clock_timestamp();
begin
  select *
    into v
  from public.jl_aviator_rounds
  where id=p_round_id
  for update;

  if v.id is null or v.status<>'LOCKED' then
    raise exception 'Rodada nao esta LOCKED';
  end if;

  v_takeoff_at:=coalesce(
    v.takeoff_at,
    v.locked_at+interval '3 seconds',
    v_now
  );

  if v_now<v_takeoff_at then
    raise exception 'Rodada ainda esta LOCKED aguardando descolagem';
  end if;

  update public.jl_aviator_rounds
     set status='FLYING',
         started_at=v_now,
         engine_due_at=null,
         takeoff_at=coalesce(takeoff_at,v_takeoff_at)
   where id=p_round_id
  returning * into v;

  perform public.jl_aviator_schedule_next_engine_event(p_round_id);
  select * into v from public.jl_aviator_rounds where id=p_round_id;
  return v;
end
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_open_next_if_due()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r public.jl_aviator_rounds;
  v_enabled boolean;
  v_commit text;
  v_now timestamptz:=clock_timestamp();
begin
  perform pg_advisory_xact_lock(hashtext('jl_aviator_engine_tick'));
  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));

  select enabled
    into v_enabled
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

  select *
    into r
  from public.jl_aviator_rounds
  order by id desc
  limit 1;

  if r.id is null
     or r.status='CANCELLED'
     or (
       r.status='SETTLED'
       and coalesce(r.next_round_at,v_now)<=v_now
     ) then
    insert into public.jl_aviator_rounds(
      status,
      betting_closes_at,
      takeoff_at,
      engine_due_at
    )
    values(
      'OPEN',
      v_now+interval '9 seconds',
      v_now+interval '12 seconds',
      v_now+interval '9 seconds'
    )
    returning * into r;

    v_commit:=public.jl_aviator_prepare_fairness(r.id);

    return jsonb_build_object(
      'opened',true,
      'round_id',r.id,
      'phase','BETTING',
      'betting_closes_at',r.betting_closes_at,
      'takeoff_at',r.takeoff_at,
      'seed_commit',v_commit,
      'fairness_version','JL-AVIATOR-PF-v2'
    );
  end if;

  return jsonb_build_object('opened',false);
end
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_tick(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v public.jl_aviator_rounds;
  v_now timestamptz:=clock_timestamp();
  v_m numeric;
  v_target numeric;
  v_auto jsonb;
  v_lost numeric:=0;
  v_bank_after numeric;
begin
  perform pg_advisory_xact_lock(
    hashtext('jl_aviator_round_'||p_round_id::text)
  );

  select *
    into v
  from public.jl_aviator_rounds
  where id=p_round_id
  for update;

  if v.id is null then
    raise exception 'Rodada nao encontrada';
  end if;

  if v.status<>'FLYING' then
    return jsonb_build_object(
      'status',v.status,
      'round_id',v.id,
      'crash_multiplier',v.crash_multiplier
    );
  end if;

  v_m:=public.jl_aviator_multiplier(v.started_at,v_now);

  -- Auto cash-outs abaixo do alvo de crash acontecem matematicamente antes
  -- do crash, mesmo que este tick chegue depois dos dois limiares.
  v_auto:=public.jl_aviator_process_auto_cashouts(
    v.id,
    v_m,
    v_now
  );

  -- O ultimo cash-out pode zerar a exposicao e estender o alvo visual.
  select *
    into v
  from public.jl_aviator_rounds
  where id=p_round_id;

  v_target:=coalesce(
    v.effective_target,
    v.financial_ceiling,
    v.visual_target
  );

  if v_m<v_target then
    perform public.jl_aviator_schedule_next_engine_event(v.id);
    return jsonb_build_object(
      'status','FLYING',
      'round_id',v.id,
      'multiplier',v_m,
      'auto_cashouts',coalesce((v_auto->>'processed')::integer,0)
    );
  end if;

  update public.jl_aviator_bets
     set status='LOST',
         payout=0
   where round_id=v.id
     and status='ACTIVE';

  if not v.lost_stakes_credited then
    select coalesce(sum(stake),0)
      into v_lost
    from public.jl_aviator_bets
    where round_id=v.id
      and status='LOST';

    update public.jl_aviator_bank
       set balance=round(balance+v_lost,2),
           updated_at=clock_timestamp()
     where id=true
    returning balance into v_bank_after;

    if v_lost>0 then
      insert into public.jl_aviator_bank_ledger(
        delta,
        balance_after,
        reason,
        request_key
      )
      values(
        v_lost,
        v_bank_after,
        'Stakes perdidos Aviator rodada '||v.id,
        'lost-round:'||v.id
      );
    end if;
  end if;

  update public.jl_aviator_rounds
     set status='CRASHED',
         crashed_at=clock_timestamp(),
         engine_due_at=clock_timestamp(),
         crash_multiplier=v_target,
         lost_stakes_credited=true
   where id=v.id
  returning * into v;

  insert into public.audit_log(action,details)
  values(
    'aviator.crashed',
    jsonb_build_object(
      'roundId',v.id,
      'crashMultiplier',v.crash_multiplier,
      'lostStakes',v_lost,
      'autoCashouts',coalesce((v_auto->>'processed')::integer,0),
      'visualExtension',v.visual_extension
    )
  );

  return jsonb_build_object(
    'status','CRASHED',
    'round_id',v.id,
    'crash_multiplier',v.crash_multiplier,
    'auto_cashouts',coalesce((v_auto->>'processed')::integer,0)
  );
end
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_cashout_locked(p_bet_id bigint, p_multiplier numeric, p_cashed_out_at timestamp with time zone, p_source text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_bet public.jl_aviator_bets;
  v_round public.jl_aviator_rounds;
  v_target numeric;
  v_payout numeric;
  v_profit numeric;
  v_tx uuid;
  v_bank_after numeric;
  v_active integer;
  v_visual numeric;
  v_extension boolean;
begin
  if p_source not in ('MANUAL','AUTO') then
    raise exception 'Origem de cash-out invalida.';
  end if;

  if p_multiplier is null or p_multiplier<1 then
    raise exception 'Multiplicador de cash-out invalido.';
  end if;

  select *
    into v_bet
  from public.jl_aviator_bets
  where id=p_bet_id
  for update;

  if v_bet.id is null then
    raise exception 'Aposta nao encontrada.';
  end if;

  if v_bet.status='CASHED_OUT' then
    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'bet_id',v_bet.id,
      'bet_uid',v_bet.bet_uid,
      'round_id',v_bet.round_id,
      'round_no',(select round_no from public.jl_aviator_rounds where id=v_bet.round_id),
      'transaction_id',v_bet.payout_transaction_id,
      'source',v_bet.cashout_source,
      'multiplier',v_bet.cashout_multiplier,
      'payout',v_bet.payout
    );
  end if;

  if v_bet.status<>'ACTIVE' then
    raise exception 'Aposta ja liquidada.';
  end if;

  select *
    into v_round
  from public.jl_aviator_rounds
  where id=v_bet.round_id;

  if v_round.id is null
     or v_round.status<>'FLYING'
     or v_round.started_at is null then
    raise exception 'Voo nao esta ativo.';
  end if;

  v_target:=coalesce(
    v_round.effective_target,
    v_round.financial_ceiling,
    v_round.visual_target
  );

  if v_target is null or p_multiplier>=v_target then
    raise exception 'Crash ja atingido.';
  end if;

  if p_source='AUTO' then
    if v_bet.auto_cashout_multiplier is null
       or round(v_bet.auto_cashout_multiplier,6)<>round(p_multiplier,6) then
      raise exception 'Cash-out automatico nao corresponde ao alvo da aposta.';
    end if;
  end if;

  v_payout:=round(v_bet.stake*p_multiplier,2);
  v_profit:=greatest(0,v_payout-v_bet.stake);
  v_tx:=gen_random_uuid();

  update public.jl_aviator_bank
     set balance=round(balance-v_profit,2),
         updated_at=clock_timestamp()
   where id=true
     and balance>=v_profit
  returning balance into v_bank_after;

  if not found then
    raise exception 'Reserva da banca inconsistente.';
  end if;

  insert into public.transactions(
    id,
    player_id,
    kind,
    amount,
    status,
    note,
    aviator_bet_id,
    aviator_operation
  )
  values(
    v_tx,
    v_bet.player_id,
    'aviator_payout',
    v_payout,
    'completed',
    case
      when p_source='AUTO'
        then 'Auto cash-out Aviator aposta '||v_bet.id||' em '||p_multiplier||'x'
      else 'Cash-out Aviator aposta '||v_bet.id||' em '||p_multiplier||'x'
    end,
    v_bet.id,
    'PAYOUT'
  );

  update public.jl_aviator_bets
     set status='CASHED_OUT',
         cashout_multiplier=p_multiplier,
         cashout_source=p_source,
         payout=v_payout,
         cashed_out_at=p_cashed_out_at,
         payout_transaction_id=v_tx
   where id=v_bet.id
     and status='ACTIVE'
  returning * into v_bet;

  if not found then
    raise exception 'Aposta ja liquidada.';
  end if;

  update public.players
     set balance=round(balance+v_payout,2),
         updated_at=clock_timestamp()
   where id=v_bet.player_id;

  select count(*)
    into v_active
  from public.jl_aviator_bets
  where round_id=v_bet.round_id
    and status='ACTIVE';

  if v_active=0 then
    select visual_extension
      into v_extension
    from public.jl_aviator_rounds
    where id=v_bet.round_id;

    if not coalesce(v_extension,false) then
      v_visual:=public.jl_aviator_set_visual_target(
        v_bet.round_id,
        p_multiplier
      );
    end if;
  end if;

  if v_profit>0 then
    insert into public.jl_aviator_bank_ledger(
      delta,
      balance_after,
      reason,
      request_key
    )
    values(
      -v_profit,
      v_bank_after,
      case
        when p_source='AUTO'
          then 'Auto cash-out Aviator aposta '||v_bet.id
        else 'Cash-out Aviator aposta '||v_bet.id
      end,
      'cashout:'||v_bet.id
    );
  end if;

  insert into public.audit_log(action,details)
  values(
    'aviator.cashout',
    jsonb_build_object(
      'roundId',v_bet.round_id,
      'roundNo',v_round.round_no,
      'betId',v_bet.id,
      'betUid',v_bet.bet_uid,
      'playerId',v_bet.player_id,
      'transactionId',v_tx,
      'source',p_source,
      'multiplier',p_multiplier,
      'payout',v_payout,
      'bankBalanceAfter',v_bank_after,
      'visualTarget',v_visual
    )
  );

  if p_source='MANUAL' then
    perform public.jl_aviator_schedule_next_engine_event(v_bet.round_id);
  end if;

  return jsonb_build_object(
    'ok',true,
    'already_processed',false,
    'bet_id',v_bet.id,
    'bet_uid',v_bet.bet_uid,
    'round_id',v_bet.round_id,
    'round_no',v_round.round_no,
    'transaction_id',v_tx,
    'source',p_source,
    'multiplier',p_multiplier,
    'payout',v_payout
  );
end
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_engine_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r public.jl_aviator_rounds;
  result jsonb;
  v_enabled boolean:=true;
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
           settled_at=coalesce(settled_at,clock_timestamp()),
           next_round_at=coalesce(next_round_at,clock_timestamp()+interval '4 seconds'),
           engine_due_at=null
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
$function$;

CREATE OR REPLACE FUNCTION public.jl_process_game_engine_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      from public.jl_aviator_rounds r
      where r.status in ('OPEN','LOCKED','FLYING','CRASHED')
        and (
          -- maintenance before takeoff must be resolved promptly
          (not v_aviator_enabled and r.status in ('OPEN','LOCKED'))
          or r.status='CRASHED'
          or r.engine_due_at is null
          or r.engine_due_at<=clock_timestamp()
        )
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
               and coalesce(latest.next_round_at,clock_timestamp())<=clock_timestamp()
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
$function$;
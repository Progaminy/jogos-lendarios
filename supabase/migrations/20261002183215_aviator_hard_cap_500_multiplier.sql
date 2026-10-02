-- Aviator: teto global real de 500x.
-- Corrige o caso em que o alvo visual era <=500x, mas o relogio local,
-- o effective_target financeiro ou a transicao para exposicao zero podiam
-- manter o voo acima de 500x antes do proximo tick.
-- A regra passa a ser aplicada no calculo base, tick, cash-out manual/auto,
-- extensao visual e verificacao da prova da rodada.

CREATE OR REPLACE FUNCTION public.jl_aviator_multiplier(p_started_at timestamp with time zone, p_at timestamp with time zone DEFAULT now())
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  select least(500::numeric, greatest(1::numeric, round(power(1.06::numeric, greatest(0, extract(epoch from (p_at-p_started_at))))::numeric, 6)));
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_set_visual_target(p_round_id bigint, p_current numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_precommitted numeric;
  v_effective numeric;
begin
  select visual_target
    into v_precommitted
  from public.jl_aviator_rounds
  where id=p_round_id
  for update;

  if not found then
    raise exception 'Rodada nao encontrada';
  end if;

  -- Compatibilidade apenas para rodadas antigas criadas antes desta migration.
  if v_precommitted is null then
    v_precommitted:=public.jl_aviator_extension_target(p_round_id,p_current);

    update public.jl_aviator_rounds
       set visual_target=v_precommitted
     where id=p_round_id;
  end if;

  v_effective:=least(500::numeric,greatest(p_current,v_precommitted));

  update public.jl_aviator_rounds
     set visual_extension=true,
         zero_exposure_at_multiplier=p_current,
         effective_target=v_effective
   where id=p_round_id
     and status='FLYING';

  return v_effective;
end
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_process_auto_cashouts(p_round_id bigint, p_current_multiplier numeric, p_processed_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_round public.jl_aviator_rounds;
  v_target numeric;
  v_item record;
  v_result jsonb;
  v_count integer:=0;
  v_total_payout numeric:=0;
begin
  select *
    into v_round
  from public.jl_aviator_rounds
  where id=p_round_id
  for update;

  if v_round.id is null or v_round.status<>'FLYING' then
    return jsonb_build_object(
      'processed',0,
      'total_payout',0
    );
  end if;

  v_target:=least(500::numeric,coalesce(
    v_round.effective_target,
    v_round.financial_ceiling,
    v_round.visual_target
  ));

  for v_item in
    select id,auto_cashout_multiplier
    from public.jl_aviator_bets
    where round_id=p_round_id
      and status='ACTIVE'
      and auto_cashout_multiplier is not null
      and auto_cashout_multiplier<=p_current_multiplier
      and auto_cashout_multiplier<v_target
    order by auto_cashout_multiplier,id
  loop
    v_result:=public.jl_aviator_cashout_locked(
      v_item.id,
      v_item.auto_cashout_multiplier,
      p_processed_at,
      'AUTO'
    );

    if coalesce((v_result->>'already_processed')::boolean,false)=false then
      v_count:=v_count+1;
      v_total_payout:=v_total_payout+coalesce(
        (v_result->>'payout')::numeric,
        0
      );
    end if;
  end loop;

  return jsonb_build_object(
    'processed',v_count,
    'total_payout',round(v_total_payout,2)
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
  v_has_active boolean:=true;
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

  v_target:=least(500::numeric,coalesce(
    v_round.effective_target,
    v_round.financial_ceiling,
    v_round.visual_target
  ));

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

  -- Per-player work remains parallel. PostgreSQL rolls all of it back if the
  -- bank reservation below cannot be acquired.
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

  -- Shared bank critical section remains short for mass cash-out.
  update public.jl_aviator_bank
     set balance=round(balance-v_profit,2),
         updated_at=clock_timestamp()
   where id=true
     and balance>=v_profit
  returning balance into v_bank_after;

  if not found then
    raise exception 'Reserva da banca inconsistente.';
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

  -- The bank row serializes the tail of concurrent cash-outs. At this point
  -- predecessors have committed and the final cash-out can observe zero
  -- exposure deterministically.
  select exists(
    select 1
    from public.jl_aviator_bets
    where round_id=v_bet.round_id
      and status='ACTIVE'
    limit 1
  )
  into v_has_active;

  if not v_has_active then
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

  -- Manual cash-out changes the remaining exposure/next relevant threshold.
  -- Keep the event-driven engine exact without restoring aggressive polling.
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
end;
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_cashout_core(p_token text, p_bet_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_probe public.jl_aviator_bets;
  v_round_id bigint;
  v_round public.jl_aviator_rounds;
  v_cashout_at timestamptz;
  v_m numeric;
begin
  select *
    into v_probe
  from public.jl_aviator_bets
  where id=p_bet_id
    and player_id=v_player_id;

  if v_probe.id is null then
    raise exception 'Aposta nao encontrada.';
  end if;

  if v_probe.status='CASHED_OUT' then
    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'bet_id',v_probe.id,
      'transaction_id',v_probe.payout_transaction_id,
      'source',v_probe.cashout_source,
      'multiplier',v_probe.cashout_multiplier,
      'payout',v_probe.payout
    );
  end if;

  perform pg_advisory_xact_lock(
    hashtext('jl_aviator_cashout_bet_'||p_bet_id::text)
  );

  select *
    into v_probe
  from public.jl_aviator_bets
  where id=p_bet_id
    and player_id=v_player_id;

  if v_probe.id is null then
    raise exception 'Aposta nao encontrada.';
  end if;

  if v_probe.status='CASHED_OUT' then
    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'bet_id',v_probe.id,
      'transaction_id',v_probe.payout_transaction_id,
      'source',v_probe.cashout_source,
      'multiplier',v_probe.cashout_multiplier,
      'payout',v_probe.payout
    );
  end if;

  if v_probe.status<>'ACTIVE' then
    raise exception 'Aposta ja liquidada.';
  end if;

  v_round_id:=v_probe.round_id;

  perform pg_advisory_xact_lock_shared(
    hashtext('jl_aviator_round_'||v_round_id::text)
  );

  select *
    into v_round
  from public.jl_aviator_rounds
  where id=v_round_id;

  select *
    into v_probe
  from public.jl_aviator_bets
  where id=p_bet_id
    and player_id=v_player_id;

  if v_probe.status='CASHED_OUT' then
    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'bet_id',v_probe.id,
      'transaction_id',v_probe.payout_transaction_id,
      'source',v_probe.cashout_source,
      'multiplier',v_probe.cashout_multiplier,
      'payout',v_probe.payout
    );
  end if;

  if v_probe.status<>'ACTIVE' then
    raise exception 'Aposta ja liquidada.';
  end if;

  if v_round.status<>'FLYING' or v_round.started_at is null then
    raise exception 'Voo nao esta ativo.';
  end if;

  v_cashout_at:=clock_timestamp();
  v_m:=public.jl_aviator_multiplier(
    v_round.started_at,
    v_cashout_at
  );

  if v_m>=least(500::numeric,coalesce(
    v_round.effective_target,
    v_round.financial_ceiling,
    v_round.visual_target
  )) then
    raise exception 'Crash ja atingido.';
  end if;

  return public.jl_aviator_cashout_locked(
    p_bet_id,
    v_m,
    v_cashout_at,
    'MANUAL'
  );
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

  v_target:=least(500::numeric,coalesce(
    v.effective_target,
    v.financial_ceiling,
    v.visual_target
  ));

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

CREATE OR REPLACE FUNCTION public.jl_aviator_round_proof(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  r public.jl_aviator_rounds;
  v_seed text;
  v_seed_commit text;
  v_visual numeric;
  v_payload text;
  v_lock_commit text;
  v_financial numeric;
  v_expected_final numeric;
  v_seed_ok boolean:=false;
  v_visual_ok boolean:=false;
  v_lock_ok boolean:=false;
  v_financial_ok boolean:=false;
  v_result_ok boolean:=false;
begin
  select *
    into r
  from public.jl_aviator_rounds
  where id=p_round_id;

  if not found then
    raise exception 'Rodada nao encontrada';
  end if;

  if r.status not in ('CRASHED','SETTLED') then
    return jsonb_build_object(
      'available',false,
      'round_id',r.id,
      'round_no',r.round_no,
      'status',r.status,
      'reason','proof_available_after_crash'
    );
  end if;

  if r.fairness_version not in ('JL-AVIATOR-PF-v2','JL-AVIATOR-PF-v3') then
    return jsonb_build_object(
      'available',false,
      'round_id',r.id,
      'round_no',r.round_no,
      'status',r.status,
      'reason','legacy_round'
    );
  end if;

  v_seed:=coalesce(r.round_seed_reveal,r.visual_seed_reveal);

  if v_seed is not null then
    v_seed_commit:=encode(extensions.digest(v_seed,'sha256'),'hex');
    v_seed_ok:=v_seed_commit=r.round_seed_commit;
  end if;

  if r.round_seed_commit is not null then
    v_visual:=case
      when r.fairness_version='JL-AVIATOR-PF-v3'
        then public.jl_aviator_fairness_visual_target_v3(r.round_seed_commit)
      else public.jl_aviator_fairness_visual_target(r.round_seed_commit)
    end;
    v_visual_ok:=round(v_visual,6)=round(r.visual_target,6);
  end if;

  v_payload:=case
    when r.fairness_version='JL-AVIATOR-PF-v3' then
      public.jl_aviator_fairness_lock_payload_v3(
        r.id,
        r.round_seed_commit,
        r.total_staked,
        r.financial_ceiling,
        r.visual_target,
        r.locked_effective_target
      )
    else
      public.jl_aviator_fairness_lock_payload(
        r.id,
        r.round_seed_commit,
        r.total_staked,
        r.financial_ceiling,
        r.visual_target,
        r.locked_effective_target
      )
  end;

  v_lock_commit:=encode(extensions.digest(v_payload,'sha256'),'hex');
  v_lock_ok:=v_lock_commit=r.lock_proof_commit;

  v_financial:=public.jl_aviator_financial_ceiling(
    r.bank_balance_snapshot,
    r.total_staked,
    r.exposure_ratio_snapshot
  );

  v_financial_ok:=case
    when r.total_staked=0 then r.financial_ceiling is null
    else round(v_financial,6)=round(r.financial_ceiling,6)
  end;

  v_expected_final:=least(500::numeric,case
    when r.visual_extension then
      greatest(
        r.visual_target,
        coalesce(r.zero_exposure_at_multiplier,r.visual_target)
      )
    else
      r.locked_effective_target
  end);

  v_result_ok:=
    v_expected_final is not null
    and r.crash_multiplier is not null
    and round(v_expected_final,6)=round(r.crash_multiplier,6);

  return jsonb_build_object(
    'available',true,
    'round_id',r.id,
    'round_no',r.round_no,
    'status',r.status,
    'fairness_version',r.fairness_version,
    'seed_commit',r.round_seed_commit,
    'seed',v_seed,
    'lock_commit',r.lock_proof_commit,
    'lock_payload',v_payload,
    'inputs',jsonb_build_object(
      'total_staked',r.total_staked,
      'visual_target',r.visual_target,
      'visual_extension',r.visual_extension,
      'financial_ceiling',r.financial_ceiling,
      'locked_effective_target',r.locked_effective_target,
      'zero_exposure_at_multiplier',r.zero_exposure_at_multiplier
    ),
    'result',jsonb_build_object(
      'actual_crash_multiplier',r.crash_multiplier,
      'expected_crash_multiplier',v_expected_final
    ),
    'checks',jsonb_build_object(
      'result_valid',v_result_ok,
      'lock_commit_valid',v_lock_ok,
      'seed_commit_valid',v_seed_ok,
      'visual_target_valid',v_visual_ok,
      'financial_ceiling_valid',v_financial_ok
    ),
    'proof_valid',
      v_seed_ok
      and v_visual_ok
      and v_lock_ok
      and v_financial_ok
      and v_result_ok,
    'published_at',r.proof_published_at
  );
end
$function$;

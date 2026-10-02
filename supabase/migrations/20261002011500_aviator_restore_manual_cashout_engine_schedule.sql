-- Aviator: restore event-driven rescheduling after the point-64
-- concurrent cash-out optimization. Keep the bank critical section short and
-- preserve zero-exposure handling, but a MANUAL cash-out must immediately
-- recompute engine_due_at because the remaining auto-cashout/visual target may
-- have changed.

create or replace function public.jl_aviator_cashout_locked(
  p_bet_id bigint,
  p_multiplier numeric,
  p_cashed_out_at timestamptz,
  p_source text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
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

revoke all on function public.jl_aviator_cashout_locked(
  bigint,numeric,timestamptz,text
) from public,anon,authenticated;

grant execute on function public.jl_aviator_cashout_locked(
  bigint,numeric,timestamptz,text
) to service_role;

-- Aviator: ledger operacional completo da banca.
-- Registra, na mesma transacao do saldo:
--   cashout:<bet_id>    -> lucro pago pela banca (delta negativo)
--   lost-round:<id>     -> stakes perdidos creditados a banca (delta positivo)
-- Ajustes administrativos continuam usando suas request_keys existentes.

create or replace function public.jl_aviator_cashout(
  p_token text,
  p_bet_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_probe public.jl_aviator_bets;
  v_round_id bigint;
  v_bet public.jl_aviator_bets;
  v_round public.jl_aviator_rounds;
  v_cashout_at timestamptz;
  v_m numeric;
  v_payout numeric;
  v_profit numeric;
  v_active integer;
  v_tx uuid:=gen_random_uuid();
  v_bank_after numeric;
  v_visual numeric;
  v_extension boolean;
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
      'multiplier',v_probe.cashout_multiplier,
      'payout',v_probe.payout
    );
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
    into v_bet
  from public.jl_aviator_bets
  where id=p_bet_id
  for update;

  if v_bet.id is null
     or v_bet.player_id<>v_player_id
     or v_bet.round_id<>v_round_id then
    raise exception 'Aposta nao encontrada.';
  end if;

  if v_bet.status='CASHED_OUT' then
    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'multiplier',v_bet.cashout_multiplier,
      'payout',v_bet.payout
    );
  end if;

  if v_bet.status<>'ACTIVE' then
    raise exception 'Aposta ja liquidada.';
  end if;

  if v_round.status<>'FLYING' or v_round.started_at is null then
    raise exception 'Voo nao esta ativo.';
  end if;

  v_cashout_at:=clock_timestamp();
  v_m:=public.jl_aviator_multiplier(v_round.started_at,v_cashout_at);

  if v_m>=coalesce(
    v_round.effective_target,
    v_round.financial_ceiling,
    v_round.visual_target
  ) then
    raise exception 'Crash ja atingido.';
  end if;

  v_payout:=round(v_bet.stake*v_m,2);
  v_profit:=greatest(0,v_payout-v_bet.stake);

  update public.jl_aviator_bets
     set status='CASHED_OUT',
         cashout_multiplier=v_m,
         payout=v_payout,
         cashed_out_at=v_cashout_at,
         payout_transaction_id=v_tx
   where id=v_bet.id;

  update public.players
     set balance=round(balance+v_payout,2),
         updated_at=clock_timestamp()
   where id=v_player_id;

  insert into public.transactions(
    id,
    player_id,
    kind,
    amount,
    status,
    note
  )
  values(
    v_tx,
    v_player_id,
    'aviator_payout',
    v_payout,
    'completed',
    'Cash-out Aviator '||v_m||'x'
  );

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
      'Cash-out Aviator aposta '||v_bet.id,
      'cashout:'||v_bet.id
    );
  end if;

  select count(*)
    into v_active
  from public.jl_aviator_bets
  where round_id=v_round_id
    and status='ACTIVE';

  if v_active=0 then
    select visual_extension
      into v_extension
    from public.jl_aviator_rounds
    where id=v_round_id;

    if not coalesce(v_extension,false) then
      v_visual:=public.jl_aviator_set_visual_target(v_round_id,v_m);
    end if;
  end if;

  insert into public.audit_log(action,details)
  values(
    'aviator.cashout',
    jsonb_build_object(
      'roundId',v_round_id,
      'betId',v_bet.id,
      'multiplier',v_m,
      'payout',v_payout,
      'bankBalanceAfter',v_bank_after,
      'visualTarget',v_visual
    )
  );

  return jsonb_build_object(
    'ok',true,
    'already_processed',false,
    'multiplier',v_m,
    'payout',v_payout
  );
end
$$;

revoke all on function public.jl_aviator_cashout(text,bigint) from public;
grant execute on function public.jl_aviator_cashout(text,bigint)
to anon,authenticated,service_role;


create or replace function public.jl_aviator_tick(p_round_id bigint)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v public.jl_aviator_rounds;
  v_m numeric;
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

  v_m:=public.jl_aviator_multiplier(v.started_at,clock_timestamp());

  if v_m<coalesce(v.effective_target,v.financial_ceiling,v.visual_target) then
    return jsonb_build_object(
      'status','FLYING',
      'round_id',v.id,
      'multiplier',v_m
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
         crash_multiplier=coalesce(
           effective_target,
           financial_ceiling,
           visual_target
         ),
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
      'visualExtension',v.visual_extension
    )
  );

  return jsonb_build_object(
    'status','CRASHED',
    'round_id',v.id,
    'crash_multiplier',v.crash_multiplier
  );
end
$$;

revoke all on function public.jl_aviator_tick(bigint)
from public,anon,authenticated;

grant execute on function public.jl_aviator_tick(bigint)
to service_role;

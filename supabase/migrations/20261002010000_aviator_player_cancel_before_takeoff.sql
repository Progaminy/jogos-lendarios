-- Aviator: cancelamento pelo jogador antes do fechamento da aposta.
-- O mesmo slot visual pode mudar Apostar -> Cancelar -> Cash-out, mas a
-- autoridade continua no servidor. Cancelar só é permitido em OPEN e antes
-- de betting_closes_at pelo relógio do servidor.

create or replace function public.jl_aviator_cancel_bet(
  p_token text,
  p_bet_id bigint,
  p_request_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_bet public.jl_aviator_bets;
  v_round public.jl_aviator_rounds;
  v_tx uuid;
  v_balance numeric;
  v_key text:=btrim(coalesce(p_request_key,''));
begin
  if length(v_key)<8 or length(v_key)>100 then
    raise exception 'Chave de cancelamento invalida.';
  end if;

  perform public.jl_rate_limit_enforce(
    'aviator_cancel_bet',
    v_player_id::text,
    5,10,20,30
  );

  perform pg_advisory_xact_lock(
    hashtextextended(
      'jl_aviator_cancel_bet:'||v_player_id::text||':'||v_key,
      0
    )
  );

  -- Serializa contra fechamento administrativo e transições críticas.
  perform pg_advisory_xact_lock_shared(hashtext('jl_aviator_maintenance'));

  select *
    into v_bet
  from public.jl_aviator_bets
  where id=p_bet_id
    and player_id=v_player_id
  for update;

  if v_bet.id is null then
    raise exception 'Aposta nao encontrada.';
  end if;

  if v_bet.status='REFUNDED' then
    select balance into v_balance
    from public.players
    where id=v_player_id;

    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'bet_id',v_bet.id,
      'round_id',v_bet.round_id,
      'transaction_id',v_bet.refund_transaction_id,
      'refund',v_bet.stake,
      'balance',v_balance
    );
  end if;

  if v_bet.status<>'ACTIVE' then
    raise exception 'Aposta ja liquidada.';
  end if;

  select *
    into v_round
  from public.jl_aviator_rounds
  where id=v_bet.round_id
  for share;

  if v_round.id is null
     or v_round.status<>'OPEN'
     or v_round.betting_closes_at is null
     or clock_timestamp()>=v_round.betting_closes_at then
    raise exception 'Cancelamento encerrado para esta rodada.';
  end if;

  perform public.jl_lock_player_wallet(v_player_id);

  select balance
    into v_balance
  from public.players
  where id=v_player_id
  for update;

  v_tx:=gen_random_uuid();

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
    v_player_id,
    'aviator_refund',
    v_bet.stake,
    'completed',
    'Cancelamento de aposta Aviator antes da descolagem · aposta '||v_bet.id,
    v_bet.id,
    'REFUND'
  );

  update public.players
     set balance=round(balance+v_bet.stake,2),
         updated_at=clock_timestamp()
   where id=v_player_id
  returning balance into v_balance;

  update public.jl_aviator_bets
     set status='REFUNDED',
         payout=v_bet.stake,
         refunded_at=clock_timestamp(),
         refund_transaction_id=v_tx
   where id=v_bet.id
     and status='ACTIVE';

  if not found then
    raise exception 'Aposta ja liquidada.';
  end if;

  insert into public.audit_log(action,details)
  values(
    'aviator.bet_cancelled',
    jsonb_build_object(
      'roundId',v_bet.round_id,
      'betId',v_bet.id,
      'playerId',v_player_id,
      'transactionId',v_tx,
      'refund',v_bet.stake,
      'cancelledAt',clock_timestamp()
    )
  );

  return jsonb_build_object(
    'ok',true,
    'already_processed',false,
    'bet_id',v_bet.id,
    'round_id',v_bet.round_id,
    'transaction_id',v_tx,
    'refund',v_bet.stake,
    'balance',v_balance
  );
end;
$function$;

revoke all on function public.jl_aviator_cancel_bet(text,bigint,text)
from public;
grant execute on function public.jl_aviator_cancel_bet(text,bigint,text)
to anon,authenticated,service_role;

-- Aviator: invariantes estruturais da idempotencia financeira fim-a-fim.
begin;

do $$
begin
  if not exists(
    select 1 from information_schema.columns
    where table_schema='public'
      and table_name='transactions'
      and column_name='aviator_bet_id'
  ) then
    raise exception 'transactions.aviator_bet_id ausente';
  end if;

  if not exists(
    select 1 from information_schema.columns
    where table_schema='public'
      and table_name='transactions'
      and column_name='aviator_operation'
  ) then
    raise exception 'transactions.aviator_operation ausente';
  end if;

  if not exists(
    select 1 from pg_indexes
    where schemaname='public'
      and indexname='transactions_aviator_bet_operation_uidx'
  ) then
    raise exception 'indice unico de operacao Aviator ausente';
  end if;

  if exists(
    select 1
    from public.transactions
    where kind in ('aviator_bet','aviator_payout','aviator_refund')
      and (aviator_bet_id is null or aviator_operation is null)
  ) then
    raise exception 'existem transacoes Aviator sem identidade financeira';
  end if;

  if exists(
    select aviator_bet_id,aviator_operation
    from public.transactions
    where aviator_bet_id is not null
    group by aviator_bet_id,aviator_operation
    having count(*)>1
  ) then
    raise exception 'operacao financeira Aviator duplicada';
  end if;

  if exists(
    select 1
    from public.jl_aviator_bets b
    where not exists(
      select 1
      from public.transactions t
      where t.aviator_bet_id=b.id
        and t.aviator_operation='BET'
        and t.kind='aviator_bet'
        and t.player_id=b.player_id
        and t.amount=-b.stake
        and t.status='completed'
    )
  ) then
    raise exception 'aposta sem debito financeiro canonico';
  end if;

  if exists(
    select 1
    from public.jl_aviator_bets b
    left join public.transactions t on t.id=b.payout_transaction_id
    where b.status='CASHED_OUT'
      and (
        t.id is null
        or t.aviator_bet_id<>b.id
        or t.aviator_operation<>'PAYOUT'
        or t.kind<>'aviator_payout'
        or t.player_id<>b.player_id
        or t.amount<>b.payout
        or t.status<>'completed'
      )
  ) then
    raise exception 'cash-out sem pagamento canonico';
  end if;

  if exists(
    select 1
    from public.jl_aviator_bets b
    left join public.transactions t on t.id=b.refund_transaction_id
    where b.status='REFUNDED'
      and (
        t.id is null
        or t.aviator_bet_id<>b.id
        or t.aviator_operation<>'REFUND'
        or t.kind<>'aviator_refund'
        or t.player_id<>b.player_id
        or t.amount<>b.stake
        or t.status<>'completed'
      )
  ) then
    raise exception 'reembolso sem transacao canonica';
  end if;
end
$$;

rollback;

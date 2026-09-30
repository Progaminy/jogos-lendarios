-- Ponto 27: ledger financeiro imutável e saldo-cache reconciliado.
begin;

do $ledger$
declare
  v_player uuid;
  v_tx uuid;
  v_ledger bigint;
  v_blocked_ledger boolean:=false;
  v_blocked_tx boolean:=false;
begin
  if to_regclass('public.player_financial_ledger') is null then
    raise exception 'player_financial_ledger ausente';
  end if;

  if exists(
    select 1
    from public.transactions t
    left join public.player_financial_ledger l on l.transaction_id=t.id
    where l.id is null
  ) then
    raise exception 'há transaction sem ledger';
  end if;

  if exists(
    select 1
    from public.players p
    where round(p.balance,2)<>round(public.jl_player_ledger_balance(p.id),2)
  ) then
    raise exception 'saldo-cache diverge do ledger';
  end if;

  insert into public.players(name,phone,pin_hash,balance)
  values(
    'LEDGER REGRESSION',
    'ledger-regression-'||gen_random_uuid()::text,
    'x',
    25
  )
  returning id into v_player;

  select t.id,l.id
    into v_tx,v_ledger
  from public.transactions t
  join public.player_financial_ledger l on l.transaction_id=t.id
  where t.player_id=v_player
    and t.kind='adjustment'
    and t.note='Saldo inicial · lançamento automático no ledger'
  limit 1;

  if v_tx is null or v_ledger is null then
    raise exception 'saldo inicial não gerou transaction + ledger';
  end if;

  if public.jl_player_ledger_balance(v_player)<>25 then
    raise exception 'saldo inicial contabilístico incorreto';
  end if;

  begin
    update public.player_financial_ledger
       set delta=delta+1
     where id=v_ledger;
  exception
    when others then
      if position('Ledger financeiro é imutável' in sqlerrm)>0 then
        v_blocked_ledger:=true;
      else
        raise;
      end if;
  end;

  if not v_blocked_ledger then
    raise exception 'ledger aceitou UPDATE';
  end if;

  begin
    update public.transactions
       set amount=amount+1
     where id=v_tx;
  exception
    when others then
      if position('Movimento financeiro confirmado é imutável' in sqlerrm)>0 then
        v_blocked_tx:=true;
      else
        raise;
      end if;
  end;

  if not v_blocked_tx then
    raise exception 'transaction aceitou alteração financeira';
  end if;
end
$ledger$;

set constraints all immediate;
rollback;

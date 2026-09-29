begin;

update public.jl_aviator_rounds
set status='CANCELLED',
    settled_at=coalesce(settled_at,clock_timestamp())
where status in ('OPEN','LOCKED','FLYING','CRASHED');

update public.jl_aviator_settings
set enabled=true,
    one_round_test=false,
    updated_at=clock_timestamp()
where id=true;

update public.jl_aviator_bank
set balance=100,
    exposure_ratio=.5,
    updated_at=clock_timestamp()
where id=true;

do $$
declare
  p1 uuid;
  p2 uuid;
  t1 text:='ledger-cashout-'||gen_random_uuid()::text;
  t2 text:='ledger-lost-'||gen_random_uuid()::text;
  rid bigint;
  b1 jsonb;
  b2 jsonb;
  c1 jsonb;
  rr public.jl_aviator_rounds;
  bank_now numeric;
  cash_delta numeric;
  lost_delta numeric;
  cash_balance numeric;
  lost_balance numeric;
  rows_found integer;
begin
  insert into public.players(name,phone,pin_hash,balance)
  values('AVIATOR LEDGER CASH','ledger-cash-'||gen_random_uuid()::text,'x',100)
  returning id into p1;

  insert into public.players(name,phone,pin_hash,balance)
  values('AVIATOR LEDGER LOST','ledger-lost-'||gen_random_uuid()::text,'x',100)
  returning id into p2;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values
    (p1,public.jl_token_hash(t1),now()+interval '1 hour'),
    (p2,public.jl_token_hash(t2),now()+interval '1 hour');

  insert into public.jl_aviator_rounds(status,betting_closes_at)
  values('OPEN',clock_timestamp()+interval '30 seconds')
  returning id into rid;

  b1:=public.jl_aviator_place_bet(t1,10,'ledger-cash-request-'||rid::text);
  b2:=public.jl_aviator_place_bet(t2,10,'ledger-lost-request-'||rid::text);

  perform public.jl_aviator_lock_round(rid);

  update public.jl_aviator_rounds
  set status='FLYING',
      started_at=clock_timestamp()-interval '1 second'
  where id=rid;

  c1:=public.jl_aviator_cashout(t1,(b1->>'bet_id')::bigint);

  select delta,balance_after
    into cash_delta,cash_balance
  from public.jl_aviator_bank_ledger
  where request_key='cashout:'||(b1->>'bet_id');

  if cash_delta is null or cash_delta>=0 then
    raise exception 'ledger do cash-out deve ter delta negativo: %',cash_delta;
  end if;

  if cash_delta<>-greatest(
    0,
    (c1->>'payout')::numeric-(b1->>'stake')::numeric
  ) then
    raise exception 'delta do cash-out nao corresponde ao lucro pago';
  end if;

  update public.jl_aviator_rounds
  set started_at=clock_timestamp()-interval '200 seconds'
  where id=rid;

  perform public.jl_aviator_tick(rid);

  select * into rr
  from public.jl_aviator_rounds
  where id=rid;

  if rr.status<>'CRASHED' then
    raise exception 'tick deveria crashar a rodada, status %',rr.status;
  end if;

  select delta,balance_after
    into lost_delta,lost_balance
  from public.jl_aviator_bank_ledger
  where request_key='lost-round:'||rid;

  if lost_delta<>10 then
    raise exception 'ledger de stake perdido esperado +10, obtido %',lost_delta;
  end if;

  select balance into bank_now
  from public.jl_aviator_bank
  where id=true;

  if lost_balance<>bank_now then
    raise exception 'balance_after final do ledger %, banca %',lost_balance,bank_now;
  end if;

  select count(*)
    into rows_found
  from public.jl_aviator_bank_ledger
  where request_key in (
    'cashout:'||(b1->>'bet_id'),
    'lost-round:'||rid
  );

  if rows_found<>2 then
    raise exception 'esperava 2 movimentos operacionais, encontrou %',rows_found;
  end if;

  perform public.jl_aviator_tick(rid);

  select count(*)
    into rows_found
  from public.jl_aviator_bank_ledger
  where request_key in (
    'cashout:'||(b1->>'bet_id'),
    'lost-round:'||rid
  );

  if rows_found<>2 then
    raise exception 'retry do tick duplicou ledger';
  end if;
end
$$;

rollback;

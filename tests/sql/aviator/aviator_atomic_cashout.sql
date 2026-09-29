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
   set balance=100000,
       exposure_ratio=.5,
       updated_at=clock_timestamp()
 where id=true;

do $atomic$
declare
  p1 uuid;
  p2 uuid;
  t1 text:='aviator-atomic-1-'||gen_random_uuid()::text;
  t2 text:='aviator-atomic-2-'||gen_random_uuid()::text;
  r1 bigint;
  r2 bigint;
  b1 jsonb;
  b2 jsonb;
  c1 jsonb;
  c2 jsonb;
  tx1 uuid;
  bal_after_first numeric;
  bal_after_second numeric;
  p2_balance numeric;
  tx_count integer;
  bet_status text;
  mutation_blocked boolean:=false;
  reserve_blocked boolean:=false;
begin
  insert into public.players(name,phone,pin_hash,balance)
  values('AVIATOR ATOMIC 1','atomic1-'||gen_random_uuid()::text,'x',100)
  returning id into p1;

  insert into public.players(name,phone,pin_hash,balance)
  values('AVIATOR ATOMIC 2','atomic2-'||gen_random_uuid()::text,'x',100)
  returning id into p2;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values
    (p1,public.jl_token_hash(t1),now()+interval '1 hour'),
    (p2,public.jl_token_hash(t2),now()+interval '1 hour');

  insert into public.jl_aviator_rounds(
    status,betting_closes_at,takeoff_at
  )
  values(
    'OPEN',
    clock_timestamp()+interval '30 seconds',
    clock_timestamp()+interval '33 seconds'
  )
  returning id into r1;

  b1:=public.jl_aviator_place_bet(
    t1,10,'atomic-bet-1-'||r1::text
  );

  perform public.jl_aviator_lock_round(r1);

  update public.jl_aviator_rounds
     set takeoff_at=clock_timestamp()-interval '1 second'
   where id=r1;

  perform public.jl_aviator_start_round(r1);

  update public.jl_aviator_rounds
     set started_at=clock_timestamp()-interval '1 second'
   where id=r1;

  c1:=public.jl_aviator_cashout(
    t1,(b1->>'bet_id')::bigint
  );

  select balance into bal_after_first
  from public.players where id=p1;

  c2:=public.jl_aviator_cashout(
    t1,(b1->>'bet_id')::bigint
  );

  select balance into bal_after_second
  from public.players where id=p1;

  if coalesce((c1->>'already_processed')::boolean,true) is not false then
    raise exception 'primeiro cash-out deveria processar: %',c1;
  end if;

  if coalesce((c2->>'already_processed')::boolean,false) is not true then
    raise exception 'retry deveria ser idempotente: %',c2;
  end if;

  if c1->>'transaction_id' is distinct from c2->>'transaction_id'
     or c1->>'payout' is distinct from c2->>'payout'
     or c1->>'multiplier' is distinct from c2->>'multiplier' then
    raise exception 'retry nao devolveu o mesmo resultado: %, %',c1,c2;
  end if;

  if bal_after_first<>bal_after_second then
    raise exception 'retry creditou saldo duas vezes: % -> %',
      bal_after_first,bal_after_second;
  end if;

  tx1:=(c1->>'transaction_id')::uuid;

  select count(*) into tx_count
  from public.transactions
  where id=tx1
    and player_id=p1
    and kind='aviator_payout';

  if tx_count<>1 then
    raise exception 'cash-out deve possuir exatamente uma transacao: %',tx_count;
  end if;

  begin
    update public.jl_aviator_bets
       set payout=payout+1
     where id=(b1->>'bet_id')::bigint;
  exception
    when others then
      if position('Cash-out Aviator ja pago e imutavel.' in sqlerrm)>0 then
        mutation_blocked:=true;
      else
        raise;
      end if;
  end;

  if not mutation_blocked then
    raise exception 'cash-out pago pôde ser alterado diretamente';
  end if;

  update public.jl_aviator_rounds
     set status='SETTLED',
         settled_at=clock_timestamp()
   where id=r1;

  update public.jl_aviator_bank
     set balance=100000,
         updated_at=clock_timestamp()
   where id=true;

  insert into public.jl_aviator_rounds(
    status,betting_closes_at,takeoff_at
  )
  values(
    'OPEN',
    clock_timestamp()+interval '30 seconds',
    clock_timestamp()+interval '33 seconds'
  )
  returning id into r2;

  b2:=public.jl_aviator_place_bet(
    t2,10,'atomic-bet-2-'||r2::text
  );

  perform public.jl_aviator_lock_round(r2);

  update public.jl_aviator_rounds
     set takeoff_at=clock_timestamp()-interval '1 second'
   where id=r2;

  perform public.jl_aviator_start_round(r2);

  update public.jl_aviator_rounds
     set started_at=clock_timestamp()-interval '1 second'
   where id=r2;

  -- Simula inconsistencia de reserva depois do snapshot da rodada.
  update public.jl_aviator_bank
     set balance=0,
         updated_at=clock_timestamp()
   where id=true;

  begin
    perform public.jl_aviator_cashout(
      t2,(b2->>'bet_id')::bigint
    );
  exception
    when others then
      if position('Reserva da banca inconsistente.' in sqlerrm)>0 then
        reserve_blocked:=true;
      else
        raise;
      end if;
  end;

  if not reserve_blocked then
    raise exception 'cash-out sem reserva deveria falhar atomicamente';
  end if;

  select status into bet_status
  from public.jl_aviator_bets
  where id=(b2->>'bet_id')::bigint;

  if bet_status<>'ACTIVE' then
    raise exception 'falha financeira deixou aposta parcialmente liquidada: %',
      bet_status;
  end if;

  select balance into p2_balance
  from public.players where id=p2;

  if p2_balance<>90 then
    raise exception 'falha financeira creditou saldo parcial: %',p2_balance;
  end if;

  select count(*) into tx_count
  from public.transactions
  where player_id=p2
    and kind='aviator_payout';

  if tx_count<>0 then
    raise exception 'falha financeira deixou transacao de payout: %',tx_count;
  end if;
end
$atomic$;

rollback;

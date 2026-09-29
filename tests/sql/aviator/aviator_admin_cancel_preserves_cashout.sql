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

do $cancel_cashout$
declare
  v_admin uuid;
  v_token text:='cancel-cashout-'||gen_random_uuid()::text;
  v_p1 uuid;
  v_p2 uuid;
  v_t1 text:='cancel-active-'||gen_random_uuid()::text;
  v_t2 text:='cancel-cashed-'||gen_random_uuid()::text;
  v_round bigint;
  v_b1 jsonb;
  v_b2 jsonb;
  v_tx uuid;
  v_result jsonb;
  v_balance1 numeric;
  v_balance2 numeric;
begin
  insert into public.admin_accounts(
    display_name,role,code_hash,code_scheme,active
  )
  values('AVIATOR CANCEL CASHOUT','admin','test-hash','bcrypt',true)
  returning id into v_admin;

  insert into public.admin_sessions(admin_id,token_hash,expires_at)
  values(
    v_admin,
    public.jl_token_hash(v_token),
    clock_timestamp()+interval '1 hour'
  );

  insert into public.players(name,phone,pin_hash,balance)
  values('CANCEL ACTIVE','ca-'||gen_random_uuid()::text,'x',100)
  returning id into v_p1;

  insert into public.players(name,phone,pin_hash,balance)
  values('CANCEL CASHED','cc-'||gen_random_uuid()::text,'x',100)
  returning id into v_p2;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values
    (v_p1,public.jl_token_hash(v_t1),clock_timestamp()+interval '1 hour'),
    (v_p2,public.jl_token_hash(v_t2),clock_timestamp()+interval '1 hour');

  insert into public.jl_aviator_rounds(
    status,betting_closes_at,takeoff_at
  )
  values(
    'OPEN',
    clock_timestamp()+interval '30 seconds',
    clock_timestamp()+interval '33 seconds'
  )
  returning id into v_round;

  v_b1:=public.jl_aviator_place_bet(
    v_t1,10,'cancel-active-'||v_round::text,null
  );
  v_b2:=public.jl_aviator_place_bet(
    v_t2,20,'cancel-cashed-'||v_round::text,null
  );

  insert into public.transactions(
    player_id,kind,amount,status,note
  )
  values(
    v_p2,'aviator_payout',30,'completed','Cancel preserve cashout test'
  )
  returning id into v_tx;

  update public.players
     set balance=round(balance+30,2),
         updated_at=clock_timestamp()
   where id=v_p2;

  update public.jl_aviator_bets
     set status='CASHED_OUT',
         cashout_multiplier=1.50,
         payout=30,
         cashed_out_at=clock_timestamp(),
         payout_transaction_id=v_tx,
         cashout_source='MANUAL'
   where id=(v_b2->>'bet_id')::bigint;

  update public.jl_aviator_rounds
     set status='FLYING',
         locked_at=clock_timestamp()-interval '4 seconds',
         started_at=clock_timestamp()-interval '1 second'
   where id=v_round;

  v_result:=public.jl_aviator_admin_cancel_round(
    v_token,
    v_round,
    'Falha técnica durante o voo'
  );

  if (v_result->>'refunded_bets')::integer<>1
     or (v_result->>'refunded_total')::numeric<>10 then
    raise exception 'somente a aposta ativa deveria ser reembolsada: %',v_result;
  end if;

  if (v_result->>'cashouts_kept')::integer<>1
     or (v_result->>'cashout_paid_kept')::numeric<>30 then
    raise exception 'cash-out já pago deveria ser preservado: %',v_result;
  end if;

  if not exists(
    select 1
    from public.jl_aviator_bets
    where id=(v_b1->>'bet_id')::bigint
      and status='REFUNDED'
      and payout=10
  ) then
    raise exception 'aposta ativa não foi reembolsada';
  end if;

  if not exists(
    select 1
    from public.jl_aviator_bets
    where id=(v_b2->>'bet_id')::bigint
      and status='CASHED_OUT'
      and payout=30
      and payout_transaction_id=v_tx
  ) then
    raise exception 'cash-out foi alterado pelo cancelamento';
  end if;

  select balance into v_balance1 from public.players where id=v_p1;
  select balance into v_balance2 from public.players where id=v_p2;

  if v_balance1<>100 then
    raise exception 'saldo do ativo deveria voltar a 100: %',v_balance1;
  end if;

  if v_balance2<>110 then
    raise exception 'cash-out não deveria receber segundo reembolso: %',v_balance2;
  end if;
end
$cancel_cashout$;

rollback;

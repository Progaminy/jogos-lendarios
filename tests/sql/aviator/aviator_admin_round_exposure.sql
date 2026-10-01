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

do $exposure$
declare
  v_admin uuid;
  v_admin_token text:='admin-exposure-'||gen_random_uuid()::text;
  v_p1 uuid;
  v_p2 uuid;
  v_p3 uuid;
  v_t1 text:='exp-p1-'||gen_random_uuid()::text;
  v_t2 text:='exp-p2-'||gen_random_uuid()::text;
  v_t3 text:='exp-p3-'||gen_random_uuid()::text;
  v_round bigint;
  v_b1 jsonb;
  v_b2 jsonb;
  v_b3 jsonb;
  v_tx uuid;
  v_state jsonb;
  v_exp jsonb;
begin
  insert into public.admin_accounts(
    display_name,role,code_hash,code_scheme,active
  )
  values('AVIATOR EXPOSURE TEST','admin','test-hash','bcrypt',true)
  returning id into v_admin;

  insert into public.admin_sessions(admin_id,token_hash,expires_at)
  values(
    v_admin,
    public.jl_token_hash(v_admin_token),
    clock_timestamp()+interval '1 hour'
  );

  insert into public.players(name,phone,pin_hash,balance)
  values('EXP P1','exp1-'||gen_random_uuid()::text,'x',100)
  returning id into v_p1;
  insert into public.players(name,phone,pin_hash,balance)
  values('EXP P2','exp2-'||gen_random_uuid()::text,'x',100)
  returning id into v_p2;
  insert into public.players(name,phone,pin_hash,balance)
  values('EXP P3','exp3-'||gen_random_uuid()::text,'x',100)
  returning id into v_p3;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values
    (v_p1,public.jl_token_hash(v_t1),clock_timestamp()+interval '1 hour'),
    (v_p2,public.jl_token_hash(v_t2),clock_timestamp()+interval '1 hour'),
    (v_p3,public.jl_token_hash(v_t3),clock_timestamp()+interval '1 hour');

  insert into public.jl_aviator_rounds(
    status,
    betting_closes_at,
    takeoff_at,
    financial_ceiling,
    visual_target
  )
  values(
    'OPEN',
    clock_timestamp()+interval '30 seconds',
    clock_timestamp()+interval '33 seconds',
    3.00,
    5.00
  )
  returning id into v_round;

  v_b1:=public.jl_aviator_place_bet(
    v_t1,10,'exp-b1-'||v_round::text,null
  );
  v_b2:=public.jl_aviator_place_bet(
    v_t2,20,'exp-b2-'||v_round::text,null
  );
  v_b3:=public.jl_aviator_place_bet(
    v_t3,5,'exp-b3-'||v_round::text,null
  );

  insert into public.transactions(
    player_id,kind,amount,status,note,aviator_bet_id,aviator_operation
  )
  values(
    v_p2,'aviator_payout',30,'completed','Exposure test cashout',
    (v_b2->>'bet_id')::bigint,'PAYOUT'
  )
  returning id into v_tx;

  update public.players
     set balance=balance+30,
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

  update public.jl_aviator_bets
     set status='LOST'
   where id=(v_b3->>'bet_id')::bigint;

  v_state:=public.jl_aviator_admin_state(v_admin_token);
  v_exp:=v_state->'exposure';

  if (v_exp->>'total_staked')::numeric<>35 then
    raise exception 'total_staked esperado 35: %',v_exp;
  end if;

  if (v_exp->>'players')::integer<>3 then
    raise exception 'players esperado 3: %',v_exp;
  end if;

  if (v_exp->>'cashouts')::integer<>1 then
    raise exception 'cashouts esperado 1: %',v_exp;
  end if;

  if (v_exp->>'cashout_paid')::numeric<>30 then
    raise exception 'cashout_paid esperado 30: %',v_exp;
  end if;

  if (v_exp->>'active_bets')::integer<>1
     or (v_exp->>'active_stake')::numeric<>10 then
    raise exception 'active exposure incorreta: %',v_exp;
  end if;

  if (v_exp->>'lost_bets')::integer<>1 then
    raise exception 'lost_bets esperado 1: %',v_exp;
  end if;

  if (v_exp->>'limit_multiplier')::numeric<>3 then
    raise exception 'limit_multiplier esperado 3: %',v_exp;
  end if;

  if (v_exp->>'potential_payment')::numeric<>60 then
    raise exception 'potential_payment esperado 60: %',v_exp;
  end if;

  if (v_state->>'stake_sum')::numeric<>35
     or (v_state->>'paid_sum')::numeric<>30 then
    raise exception 'compatibilidade legacy quebrada: %',v_state;
  end if;
end
$exposure$;

rollback;

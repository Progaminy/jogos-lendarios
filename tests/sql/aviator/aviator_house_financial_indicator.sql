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

do $house_indicator$
declare
  v_admin uuid;
  v_admin_token text:='house-indicator-'||gen_random_uuid()::text;
  v_p1 uuid;
  v_p2 uuid;
  v_p3 uuid;
  v_t1 text:='house-p1-'||gen_random_uuid()::text;
  v_t2 text:='house-p2-'||gen_random_uuid()::text;
  v_t3 text:='house-p3-'||gen_random_uuid()::text;
  v_round bigint;
  v_b1 jsonb;
  v_b2 jsonb;
  v_b3 jsonb;
  v_tx uuid;
  v_state jsonb;
  v_house jsonb;
begin
  insert into public.admin_accounts(
    display_name,role,code_hash,code_scheme,active
  )
  values('HOUSE INDICATOR TEST','admin','test-hash','bcrypt',true)
  returning id into v_admin;

  insert into public.admin_sessions(admin_id,token_hash,expires_at)
  values(
    v_admin,
    public.jl_token_hash(v_admin_token),
    clock_timestamp()+interval '1 hour'
  );

  insert into public.players(name,phone,pin_hash,balance)
  values('HOUSE P1','house1-'||gen_random_uuid()::text,'x',100)
  returning id into v_p1;
  insert into public.players(name,phone,pin_hash,balance)
  values('HOUSE P2','house2-'||gen_random_uuid()::text,'x',100)
  returning id into v_p2;
  insert into public.players(name,phone,pin_hash,balance)
  values('HOUSE P3','house3-'||gen_random_uuid()::text,'x',100)
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
    v_t1,10,'house-b1-'||v_round::text,null
  );
  v_b2:=public.jl_aviator_place_bet(
    v_t2,20,'house-b2-'||v_round::text,null
  );
  v_b3:=public.jl_aviator_place_bet(
    v_t3,5,'house-b3-'||v_round::text,null
  );

  insert into public.transactions(
    player_id,kind,amount,status,note
  )
  values(
    v_p2,'aviator_payout',30,'completed','House indicator cashout'
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
  v_house:=v_state->'house';

  if (v_house->>'bank_balance')::numeric<>100 then
    raise exception 'bank_balance esperado 100: %',v_house;
  end if;

  if (v_house->>'risk_budget')::numeric<>50 then
    raise exception 'risk_budget esperado 50: %',v_house;
  end if;

  if (v_house->>'active_liability')::numeric<>20 then
    raise exception 'active_liability esperado 20: %',v_house;
  end if;

  if (v_house->>'available_after_worst_case')::numeric<>80 then
    raise exception 'available_after_worst_case esperado 80: %',v_house;
  end if;

  if (v_house->>'risk_usage_pct')::numeric<>40 then
    raise exception 'risk_usage_pct esperado 40: %',v_house;
  end if;

  if (v_house->>'cashout_profit_paid')::numeric<>10 then
    raise exception 'cashout_profit_paid esperado 10: %',v_house;
  end if;

  if (v_house->>'round_realized_result')::numeric<>-5 then
    raise exception 'round_realized_result esperado -5: %',v_house;
  end if;

  if v_house->>'status'<>'HEALTHY' then
    raise exception 'status esperado HEALTHY: %',v_house;
  end if;

  if v_house->>'updated_at' is null then
    raise exception 'updated_at ausente: %',v_house;
  end if;
end
$house_indicator$;

rollback;

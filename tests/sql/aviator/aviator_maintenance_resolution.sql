begin;

update public.jl_aviator_rounds
   set status='CANCELLED',
       settled_at=coalesce(settled_at,clock_timestamp())
 where status in ('OPEN','LOCKED','FLYING','CRASHED');

update public.jl_aviator_settings
   set enabled=false,
       one_round_test=false,
       maintenance_message='Aviator brevemente.',
       updated_at=clock_timestamp()
 where id=true;

update public.jl_aviator_bank
   set balance=100000,
       exposure_ratio=.5,
       updated_at=clock_timestamp()
 where id=true;

do $maintenance_resolution$
declare
  v_admin uuid;
  v_admin_token text:='maint-resolve-admin-'||gen_random_uuid()::text;
  v_p1 uuid;
  v_p2 uuid;
  v_p3 uuid;
  v_t1 text:='maint-open-'||gen_random_uuid()::text;
  v_t2 text:='maint-locked-'||gen_random_uuid()::text;
  v_t3 text:='maint-flying-'||gen_random_uuid()::text;
  v_r1 bigint;
  v_r2 bigint;
  v_r3 bigint;
  v_b1 jsonb;
  v_b2 jsonb;
  v_b3 jsonb;
  v_tx_count bigint;
  v_balance numeric;
  v_status text;
  v_tick jsonb;
begin
  insert into public.admin_accounts(
    display_name,role,code_hash,code_scheme,active
  )
  values('AVIATOR MAINT RESOLVE','admin','test-hash','bcrypt',true)
  returning id into v_admin;

  insert into public.admin_sessions(admin_id,token_hash,expires_at)
  values(
    v_admin,
    public.jl_token_hash(v_admin_token),
    clock_timestamp()+interval '1 hour'
  );

  insert into public.players(name,phone,pin_hash,balance)
  values('MAINT OPEN','mopen-'||gen_random_uuid()::text,'x',100)
  returning id into v_p1;
  insert into public.players(name,phone,pin_hash,balance)
  values('MAINT LOCKED','mlocked-'||gen_random_uuid()::text,'x',100)
  returning id into v_p2;
  insert into public.players(name,phone,pin_hash,balance)
  values('MAINT FLYING','mflying-'||gen_random_uuid()::text,'x',100)
  returning id into v_p3;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values
    (v_p1,public.jl_token_hash(v_t1),clock_timestamp()+interval '1 hour'),
    (v_p2,public.jl_token_hash(v_t2),clock_timestamp()+interval '1 hour'),
    (v_p3,public.jl_token_hash(v_t3),clock_timestamp()+interval '1 hour');

  -- OPEN + dinheiro: fecha, reembolsa e cancela imediatamente.
  perform public.jl_aviator_admin_reopen(v_admin_token);

  insert into public.jl_aviator_rounds(status,betting_closes_at,takeoff_at)
  values(
    'OPEN',
    clock_timestamp()+interval '30 seconds',
    clock_timestamp()+interval '33 seconds'
  )
  returning id into v_r1;

  v_b1:=public.jl_aviator_place_bet(
    v_t1,10,'maint-open-'||v_r1::text,null
  );

  perform public.jl_aviator_admin_close(v_admin_token);

  select status into v_status
  from public.jl_aviator_rounds
  where id=v_r1;

  if v_status<>'CANCELLED' then
    raise exception 'OPEN em manutenção deveria CANCELLED; status=%',v_status;
  end if;

  if not exists(
    select 1
    from public.jl_aviator_bets
    where id=(v_b1->>'bet_id')::bigint
      and status='REFUNDED'
      and payout=stake
      and refunded_at is not null
      and refund_transaction_id is not null
  ) then
    raise exception 'aposta OPEN não foi reembolsada corretamente';
  end if;

  select balance into v_balance from public.players where id=v_p1;
  if v_balance<>100 then
    raise exception 'saldo OPEN não voltou a 100: %',v_balance;
  end if;

  select count(*) into v_tx_count
  from public.transactions
  where player_id=v_p1
    and kind='aviator_refund'
    and amount=10;

  if v_tx_count<>1 then
    raise exception 'reembolso OPEN deveria gerar 1 transação, gerou %',v_tx_count;
  end if;

  -- Repetir fecho não duplica dinheiro/transação.
  perform public.jl_aviator_admin_close(v_admin_token);

  select balance into v_balance from public.players where id=v_p1;
  if v_balance<>100 then
    raise exception 'segundo fecho duplicou saldo: %',v_balance;
  end if;

  select count(*) into v_tx_count
  from public.transactions
  where player_id=v_p1 and kind='aviator_refund';

  if v_tx_count<>1 then
    raise exception 'segundo fecho duplicou reembolso: %',v_tx_count;
  end if;

  -- LOCKED ainda não descolou: também cancela/reembolsa.
  perform public.jl_aviator_admin_reopen(v_admin_token);

  insert into public.jl_aviator_rounds(status,betting_closes_at,takeoff_at)
  values(
    'OPEN',
    clock_timestamp()+interval '30 seconds',
    clock_timestamp()+interval '33 seconds'
  )
  returning id into v_r2;

  v_b2:=public.jl_aviator_place_bet(
    v_t2,15,'maint-locked-'||v_r2::text,null
  );

  perform public.jl_aviator_lock_round(v_r2);
  perform public.jl_aviator_admin_close(v_admin_token);

  if not exists(
    select 1
    from public.jl_aviator_rounds
    where id=v_r2 and status='CANCELLED'
  ) then
    raise exception 'LOCKED em manutenção deveria CANCELLED';
  end if;

  if not exists(
    select 1
    from public.jl_aviator_bets
    where id=(v_b2->>'bet_id')::bigint
      and status='REFUNDED'
      and payout=15
  ) then
    raise exception 'LOCKED não foi reembolsada';
  end if;

  select balance into v_balance from public.players where id=v_p2;
  if v_balance<>100 then
    raise exception 'saldo LOCKED não foi restaurado: %',v_balance;
  end if;

  -- FLYING: manutenção não cancela nem reembolsa arbitrariamente.
  -- O motor continua até crash e liquidação.
  perform public.jl_aviator_admin_reopen(v_admin_token);

  insert into public.jl_aviator_rounds(status,betting_closes_at,takeoff_at)
  values(
    'OPEN',
    clock_timestamp()+interval '30 seconds',
    clock_timestamp()+interval '33 seconds'
  )
  returning id into v_r3;

  v_b3:=public.jl_aviator_place_bet(
    v_t3,10,'maint-flying-'||v_r3::text,null
  );

  perform public.jl_aviator_lock_round(v_r3);

  update public.jl_aviator_rounds
     set betting_closes_at=clock_timestamp()-interval '6 seconds',
         takeoff_at=clock_timestamp()-interval '3 seconds'
   where id=v_r3;

  perform public.jl_aviator_start_round(v_r3);

  update public.jl_aviator_rounds
     set started_at=clock_timestamp(),
         financial_ceiling=1.50,
         locked_effective_target=1.50,
         effective_target=1.50,
         visual_extension=false
   where id=v_r3;

  perform public.jl_aviator_admin_close(v_admin_token);

  select status into v_status
  from public.jl_aviator_rounds
  where id=v_r3;

  if v_status<>'FLYING' then
    raise exception 'FLYING não deve ser cancelada/reembolsada; status=%',v_status;
  end if;

  if not exists(
    select 1
    from public.jl_aviator_bets
    where id=(v_b3->>'bet_id')::bigint
      and status='ACTIVE'
  ) then
    raise exception 'aposta FLYING deveria continuar ACTIVE durante drenagem';
  end if;

  update public.jl_aviator_rounds
     set started_at=clock_timestamp()-interval '20 seconds'
   where id=v_r3;

  v_tick:=public.jl_aviator_engine_tick();
  if v_tick->>'status'<>'CRASHED' then
    raise exception 'FLYING em manutenção deveria atingir CRASHED: %',v_tick;
  end if;

  v_tick:=public.jl_aviator_engine_tick();
  if v_tick->>'status'<>'SETTLED' then
    raise exception 'CRASHED em manutenção deveria concluir SETTLED: %',v_tick;
  end if;

  if exists(
    select 1
    from public.jl_aviator_bets
    where round_id=v_r3 and status='ACTIVE'
  ) then
    raise exception 'aposta ficou ACTIVE após liquidação em manutenção';
  end if;

  if not exists(
    select 1
    from public.jl_aviator_bets
    where id=(v_b3->>'bet_id')::bigint
      and status='LOST'
  ) then
    raise exception 'aposta FLYING deveria terminar LOST neste cenário';
  end if;

  if exists(
    select 1
    from public.jl_aviator_bets b
    join public.jl_aviator_rounds r on r.id=b.round_id
    where r.status in ('CANCELLED','SETTLED')
      and b.status='ACTIVE'
  ) then
    raise exception 'há aposta ACTIVE presa em rodada finalizada';
  end if;
end
$maintenance_resolution$;

rollback;

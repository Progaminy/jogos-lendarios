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

do $separation$
declare
  p1 uuid;
  p2 uuid;
  t1 text:='visual-separation-1-'||gen_random_uuid()::text;
  t2 text:='visual-separation-2-'||gen_random_uuid()::text;
  r1 bigint;
  r2 bigint;
  b1 jsonb;
  b2 jsonb;
  c1 jsonb;
  tick jsonb;
  public_state jsonb;
  persisted_multiplier numeric;
  persisted_payout numeric;
  persisted_status text;
  persisted_crash numeric;
  arglist text;
begin
  -- O RPC financeiro de cash-out nao aceita multiplicador/payout do navegador.
  select pg_get_function_identity_arguments(
    'public.jl_aviator_cashout(text,bigint)'::regprocedure
  ) into arglist;

  if arglist<>'p_token text, p_bet_id bigint' then
    raise exception 'cash-out ganhou input financeiro do cliente: %',arglist;
  end if;

  if has_table_privilege('anon','public.jl_aviator_rounds','UPDATE')
     or has_table_privilege('authenticated','public.jl_aviator_rounds','UPDATE')
     or has_table_privilege('anon','public.jl_aviator_bets','UPDATE')
     or has_table_privilege('authenticated','public.jl_aviator_bets','UPDATE') then
    raise exception 'cliente possui UPDATE direto em tabelas financeiras do Aviator';
  end if;

  insert into public.players(name,phone,pin_hash,balance)
  values('VISUAL SEP 1','vsep1-'||gen_random_uuid()::text,'x',100)
  returning id into p1;

  insert into public.players(name,phone,pin_hash,balance)
  values('VISUAL SEP 2','vsep2-'||gen_random_uuid()::text,'x',100)
  returning id into p2;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values
    (p1,public.jl_token_hash(t1),now()+interval '1 hour'),
    (p2,public.jl_token_hash(t2),now()+interval '1 hour');

  -- Rodada 1: payout manual e calculado pelo servidor.
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
    t1,10,'visual-sep-cashout-'||r1::text
  );

  perform public.jl_aviator_lock_round(r1);

  update public.jl_aviator_rounds
     set betting_closes_at=clock_timestamp()-interval '6 seconds',
         takeoff_at=clock_timestamp()-interval '3 seconds'
   where id=r1;

  perform public.jl_aviator_start_round(r1);

  update public.jl_aviator_rounds
     set started_at=clock_timestamp()-interval '2 seconds',
         financial_ceiling=5,
         locked_effective_target=5,
         effective_target=5,
         visual_extension=false
   where id=r1;

  c1:=public.jl_aviator_cashout(
    t1,(b1->>'bet_id')::bigint
  );

  select cashout_multiplier,payout,status
    into persisted_multiplier,persisted_payout,persisted_status
  from public.jl_aviator_bets
  where id=(b1->>'bet_id')::bigint;

  if persisted_status<>'CASHED_OUT'
     or persisted_multiplier is null
     or persisted_multiplier<=1
     or persisted_payout<>round(10*persisted_multiplier,2) then
    raise exception 'cash-out financeiro nao foi decidido/persistido pelo servidor';
  end if;

  if (c1->>'multiplier')::numeric<>persisted_multiplier
     or (c1->>'payout')::numeric<>persisted_payout then
    raise exception 'resposta visual diverge do registro financeiro persistido';
  end if;

  update public.jl_aviator_rounds
     set status='SETTLED',
         settled_at=clock_timestamp()
   where id=r1;

  -- Rodada 2: crash e perda registrados pelo motor antes de qualquer UI.
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
    t2,10,'visual-sep-crash-'||r2::text
  );

  perform public.jl_aviator_lock_round(r2);

  update public.jl_aviator_rounds
     set betting_closes_at=clock_timestamp()-interval '6 seconds',
         takeoff_at=clock_timestamp()-interval '3 seconds'
   where id=r2;

  perform public.jl_aviator_start_round(r2);

  update public.jl_aviator_rounds
     set started_at=clock_timestamp()-interval '20 seconds',
         financial_ceiling=1.50,
         locked_effective_target=1.50,
         effective_target=1.50,
         visual_extension=false
   where id=r2;

  tick:=public.jl_aviator_tick(r2);

  if tick->>'status'<>'CRASHED' then
    raise exception 'motor deveria persistir CRASHED: %',tick;
  end if;

  select status,crash_multiplier
    into persisted_status,persisted_crash
  from public.jl_aviator_rounds
  where id=r2;

  if persisted_status<>'CRASHED' or persisted_crash<>1.50 then
    raise exception 'crash nao foi persistido pelo servidor: status %, crash %',
      persisted_status,persisted_crash;
  end if;

  select status
    into persisted_status
  from public.jl_aviator_bets
  where id=(b2->>'bet_id')::bigint;

  if persisted_status<>'LOST' then
    raise exception 'aposta deveria estar LOST antes da UI: %',persisted_status;
  end if;

  public_state:=public.jl_aviator_public_state();

  if public_state->'round'->>'status'<>'CRASHED'
     or (public_state->'round'->>'crash_multiplier')::numeric<>persisted_crash then
    raise exception 'UI publica nao esta apenas refletindo o crash persistido: %',
      public_state;
  end if;
end
$separation$;

rollback;

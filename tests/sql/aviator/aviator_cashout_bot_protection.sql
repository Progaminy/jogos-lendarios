-- Ponto 34: proteção contra bots/requisições repetidas no cash-out.
begin;

do $test$
declare
  v_bet_id bigint;
  v_round_id bigint;
  v_player uuid;
  v_setup jsonb;
  v_token text:='point34-'||gen_random_uuid()::text;
  v_subject text;
  v_request1 text:='cashout-'||gen_random_uuid()::text;
  v_request2 text:='cashout-'||gen_random_uuid()::text;
  v_result jsonb;
  v_result2 jsonb;
  v_attempts bigint;
  v_blocked bigint;
  v_token_hits bigint;
  v_payouts_before bigint;
  v_payouts_after bigint;
begin
  if to_regclass('public.jl_aviator_cashout_guard') is null then
    raise exception 'cashout guard ausente';
  end if;

  if not exists(
    select 1
    from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relname='jl_aviator_cashout_guard'
      and c.relrowsecurity
  ) then
    raise exception 'RLS do cashout guard ausente';
  end if;

  if has_function_privilege(
       'anon','public.jl_aviator_cashout_core(text,bigint)','EXECUTE'
     )
     or has_function_privilege(
       'authenticated','public.jl_aviator_cashout_core(text,bigint)','EXECUTE'
     ) then
    raise exception 'cashout core exposto ao cliente';
  end if;

  if has_function_privilege(
       'anon','public.jl_aviator_cashout_bot_guard(uuid,bigint,integer)','EXECUTE'
     )
     or has_function_privilege(
       'authenticated','public.jl_aviator_cashout_bot_guard(uuid,bigint,integer)','EXECUTE'
     ) then
    raise exception 'bot guard exposto ao cliente';
  end if;

  if not has_function_privilege(
       'anon','public.jl_aviator_cashout(text,bigint,text)','EXECUTE'
     ) then
    raise exception 'cashout público com request_key indisponível';
  end if;

  if has_table_privilege('service_role','public.jl_aviator_cashout_guard','INSERT')
     or has_table_privilege('service_role','public.jl_aviator_cashout_guard','UPDATE')
     or has_table_privilege('service_role','public.jl_aviator_cashout_guard','DELETE') then
    raise exception 'service_role possui escrita direta no cashout guard';
  end if;

  -- O teste deve ser autossuficiente: cria a própria aposta LOST em vez de
  -- depender de dados deixados por outro teste/transação.
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

  insert into public.players(name,phone,pin_hash,balance)
  values(
    'AVIATOR BOT GUARD TEST',
    'bot-guard-'||gen_random_uuid()::text,
    'x',
    100
  )
  returning id into v_player;

  v_subject:=public.jl_token_hash(v_token);

  insert into public.player_sessions(
    player_id,token_hash,expires_at,last_seen_at
  )
  values(
    v_player,v_subject,now()+interval '10 minutes',now()
  );

  insert into public.jl_aviator_rounds(
    status,betting_closes_at,takeoff_at
  )
  values(
    'OPEN',
    clock_timestamp()+interval '30 seconds',
    clock_timestamp()+interval '33 seconds'
  )
  returning id into v_round_id;

  v_setup:=public.jl_aviator_place_bet(
    v_token,
    10,
    'bot-guard-setup-'||v_round_id::text
  );

  v_bet_id:=(v_setup->>'bet_id')::bigint;

  if v_bet_id is null then
    raise exception 'Falha ao criar aposta da regressão: %',v_setup;
  end if;

  update public.jl_aviator_bets
     set status='LOST',
         payout=0
   where id=v_bet_id;

  update public.jl_aviator_rounds
     set status='SETTLED',
         settled_at=clock_timestamp()
   where id=v_round_id;

  delete from public.jl_aviator_cashout_guard
  where bet_id=v_bet_id;

  delete from public.jl_api_rate_limits
  where subject_key in (v_subject,v_bet_id::text)
    and scope like 'aviator_cashout_%';

  select count(*) into v_payouts_before
  from public.transactions
  where aviator_bet_id=v_bet_id
    and aviator_operation='PAYOUT';

  v_result:=public.jl_aviator_cashout(
    v_token,v_bet_id,v_request1
  );

  if coalesce((v_result->>'ok')::boolean,true) then
    raise exception 'cash-out de aposta LOST não foi recusado';
  end if;

  if v_result->>'error_code'<>'BET_SETTLED' then
    raise exception 'erro inesperado: %',v_result;
  end if;

  select total_attempts,blocked_attempts
  into v_attempts,v_blocked
  from public.jl_aviator_cashout_guard
  where bet_id=v_bet_id;

  if v_attempts<>1 or v_blocked<>0 then
    raise exception 'primeira tentativa rejeitada não persistiu no guard';
  end if;

  select coalesce(sum(hits),0)
  into v_token_hits
  from public.jl_api_rate_limits
  where subject_key=v_subject
    and scope like 'aviator_cashout_token:%';

  if v_token_hits<2 then
    raise exception 'rate-limit do token foi perdido após rejeição';
  end if;

  update public.jl_aviator_cashout_guard
  set last_attempt_at=clock_timestamp()
  where bet_id=v_bet_id;

  v_result2:=public.jl_aviator_cashout(
    v_token,v_bet_id,v_request2
  );

  if v_result2->>'error_code'<>'BOT_TOO_FAST' then
    raise exception 'tentativa sub-250ms não foi bloqueada: %',v_result2;
  end if;

  select total_attempts,blocked_attempts
  into v_attempts,v_blocked
  from public.jl_aviator_cashout_guard
  where bet_id=v_bet_id;

  if v_attempts<2 or v_blocked<1 then
    raise exception 'tentativa rápida não foi contabilizada';
  end if;

  select count(*) into v_payouts_after
  from public.transactions
  where aviator_bet_id=v_bet_id
    and aviator_operation='PAYOUT';

  if v_payouts_after<>v_payouts_before then
    raise exception 'proteção anti-bot criou payout indevido';
  end if;
end
$test$;

rollback;

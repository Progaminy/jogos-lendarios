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

do $autocash$
declare
  p_auto uuid;
  p_manual uuid;
  p_equal uuid;
  t_auto text:='aviator-auto-'||gen_random_uuid()::text;
  t_manual text:='aviator-manual-'||gen_random_uuid()::text;
  t_equal text:='aviator-equal-'||gen_random_uuid()::text;
  r1 bigint;
  r2 bigint;
  b_auto jsonb;
  b_manual jsonb;
  b_equal jsonb;
  tick jsonb;
  retry jsonb;
  invalid_blocked boolean:=false;
  auto_status text;
  manual_status text;
  equal_status text;
  auto_source text;
  auto_multiplier numeric;
  auto_payout numeric;
  auto_balance numeric;
  manual_balance numeric;
  equal_balance numeric;
  payout_count integer;
  ledger_count integer;
  audit_count integer;
  tx_id uuid;
  retry_balance numeric;
begin
  insert into public.players(name,phone,pin_hash,balance)
  values('AVIATOR AUTO','auto-'||gen_random_uuid()::text,'x',100)
  returning id into p_auto;

  insert into public.players(name,phone,pin_hash,balance)
  values('AVIATOR MANUAL','manual-'||gen_random_uuid()::text,'x',100)
  returning id into p_manual;

  insert into public.players(name,phone,pin_hash,balance)
  values('AVIATOR EQUAL','equal-'||gen_random_uuid()::text,'x',100)
  returning id into p_equal;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values
    (p_auto,public.jl_token_hash(t_auto),now()+interval '1 hour'),
    (p_manual,public.jl_token_hash(t_manual),now()+interval '1 hour'),
    (p_equal,public.jl_token_hash(t_equal),now()+interval '1 hour');

  insert into public.jl_aviator_rounds(
    status,betting_closes_at,takeoff_at
  )
  values(
    'OPEN',
    clock_timestamp()+interval '30 seconds',
    clock_timestamp()+interval '33 seconds'
  )
  returning id into r1;

  begin
    perform public.jl_aviator_place_bet(
      t_auto,10,'auto-invalid-'||r1::text,1.005
    );
  exception
    when others then
      if position('pelo menos 1,01x' in sqlerrm)>0 then
        invalid_blocked:=true;
      else
        raise;
      end if;
  end;

  if not invalid_blocked then
    raise exception 'auto cash-out com mais de 2 casas/abaixo do minimo deveria falhar';
  end if;

  b_auto:=public.jl_aviator_place_bet(
    t_auto,10,'auto-valid-'||r1::text,1.50
  );

  b_manual:=public.jl_aviator_place_bet(
    t_manual,10,'manual-valid-'||r1::text
  );

  if (b_auto->>'auto_cashout_multiplier')::numeric<>1.50 then
    raise exception 'auto cash-out nao foi gravado na aposta: %',b_auto;
  end if;

  if b_manual->>'auto_cashout_multiplier' is not null then
    raise exception 'aposta sem auto deveria permanecer sem alvo: %',b_manual;
  end if;

  perform public.jl_aviator_lock_round(r1);

  update public.jl_aviator_rounds
     set betting_closes_at=clock_timestamp()-interval '14 seconds',
         takeoff_at=clock_timestamp()-interval '11 seconds'
   where id=r1;

  perform public.jl_aviator_start_round(r1);

  update public.jl_aviator_rounds
     set started_at=clock_timestamp()-interval '10 seconds',
         financial_ceiling=1.60,
         locked_effective_target=1.60,
         effective_target=1.60,
         visual_extension=false
   where id=r1;

  tick:=public.jl_aviator_tick(r1);

  if tick->>'status'<>'CRASHED'
     or (tick->>'auto_cashouts')::integer<>1 then
    raise exception 'tick deveria auto-pagar 1 aposta antes do crash: %',tick;
  end if;

  select
    status,
    cashout_source,
    cashout_multiplier,
    payout,
    payout_transaction_id
  into
    auto_status,
    auto_source,
    auto_multiplier,
    auto_payout,
    tx_id
  from public.jl_aviator_bets
  where id=(b_auto->>'bet_id')::bigint;

  if auto_status<>'CASHED_OUT'
     or auto_source<>'AUTO'
     or auto_multiplier<>1.50
     or auto_payout<>15.00
     or tx_id is null then
    raise exception
      'auto cash-out incorreto: status %, source %, multiplier %, payout %, tx %',
      auto_status,auto_source,auto_multiplier,auto_payout,tx_id;
  end if;

  select status
    into manual_status
  from public.jl_aviator_bets
  where id=(b_manual->>'bet_id')::bigint;

  if manual_status<>'LOST' then
    raise exception 'aposta sem auto deveria perder no crash: %',manual_status;
  end if;

  select balance into auto_balance
  from public.players where id=p_auto;

  select balance into manual_balance
  from public.players where id=p_manual;

  if auto_balance<>105 then
    raise exception 'saldo do auto cash-out deveria ser 105, recebeu %',auto_balance;
  end if;

  if manual_balance<>90 then
    raise exception 'saldo da aposta perdida deveria ser 90, recebeu %',manual_balance;
  end if;

  select count(*) into payout_count
  from public.transactions
  where id=tx_id
    and player_id=p_auto
    and kind='aviator_payout'
    and amount=15.00;

  if payout_count<>1 then
    raise exception 'auto cash-out deve ter uma unica transacao: %',payout_count;
  end if;

  select count(*) into ledger_count
  from public.jl_aviator_bank_ledger
  where request_key='cashout:'||(b_auto->>'bet_id');

  if ledger_count<>1 then
    raise exception 'auto cash-out deve debitar a banca uma vez: %',ledger_count;
  end if;

  select count(*) into audit_count
  from public.audit_log
  where action='aviator.cashout'
    and details->>'betId'=b_auto->>'bet_id'
    and details->>'source'='AUTO';

  if audit_count<>1 then
    raise exception 'auto cash-out deve ter uma auditoria: %',audit_count;
  end if;

  retry:=public.jl_aviator_cashout(
    t_auto,(b_auto->>'bet_id')::bigint
  );

  select balance into retry_balance
  from public.players where id=p_auto;

  if coalesce((retry->>'already_processed')::boolean,false) is not true
     or retry->>'source'<>'AUTO'
     or (retry->>'multiplier')::numeric<>1.50
     or (retry->>'payout')::numeric<>15.00
     or (retry->>'transaction_id')::uuid<>tx_id then
    raise exception 'retry depois do auto nao foi idempotente: %',retry;
  end if;

  if retry_balance<>auto_balance then
    raise exception 'retry depois do auto duplicou saldo: % -> %',
      auto_balance,retry_balance;
  end if;

  -- Segunda rodada: auto exatamente no mesmo multiplicador do crash perde.
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

  b_equal:=public.jl_aviator_place_bet(
    t_equal,10,'auto-equal-'||r2::text,1.60
  );

  perform public.jl_aviator_lock_round(r2);

  update public.jl_aviator_rounds
     set betting_closes_at=clock_timestamp()-interval '14 seconds',
         takeoff_at=clock_timestamp()-interval '11 seconds'
   where id=r2;

  perform public.jl_aviator_start_round(r2);

  update public.jl_aviator_rounds
     set started_at=clock_timestamp()-interval '10 seconds',
         financial_ceiling=1.60,
         locked_effective_target=1.60,
         effective_target=1.60,
         visual_extension=false
   where id=r2;

  tick:=public.jl_aviator_tick(r2);

  select status into equal_status
  from public.jl_aviator_bets
  where id=(b_equal->>'bet_id')::bigint;

  select balance into equal_balance
  from public.players where id=p_equal;

  if equal_status<>'LOST' then
    raise exception 'auto igual ao crash deve perder: status %',equal_status;
  end if;

  if equal_balance<>90 then
    raise exception 'auto igual ao crash nao deve pagar: saldo %',equal_balance;
  end if;

  select count(*) into payout_count
  from public.transactions
  where player_id=p_equal
    and kind='aviator_payout';

  if payout_count<>0 then
    raise exception 'auto igual ao crash criou payout: %',payout_count;
  end if;

  if has_function_privilege(
    'anon',
    'public.jl_aviator_process_auto_cashouts(bigint,numeric,timestamptz)',
    'EXECUTE'
  ) then
    raise exception 'processador interno de auto cash-out exposto a anon';
  end if;
end
$autocash$;

rollback;

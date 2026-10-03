begin;

update public.jl_aviator_rounds
   set status='CANCELLED',
       settled_at=coalesce(settled_at,clock_timestamp())
 where status in ('OPEN','LOCKED','FLYING','CRASHED');

do $live_bank$
declare
  v_admin uuid;
  v_token text:='admin-live-bank-'||gen_random_uuid()::text;
  v_round bigint;
  v_result jsonb;
  v_state jsonb;
  v_balance numeric;
begin
  insert into public.admin_accounts(
    display_name,role,code_hash,code_scheme,active
  )
  values(
    'AVIATOR LIVE BANK TEST','admin','test-hash','bcrypt',true
  )
  returning id into v_admin;

  insert into public.admin_sessions(admin_id,token_hash,expires_at)
  values(
    v_admin,
    public.jl_token_hash(v_token),
    clock_timestamp()+interval '1 hour'
  );

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

  insert into public.jl_aviator_rounds(
    status,betting_closes_at,takeoff_at
  )
  values(
    'OPEN',
    clock_timestamp()+interval '30 seconds',
    clock_timestamp()+interval '33 seconds'
  )
  returning id into v_round;

  v_result:=public.jl_aviator_admin_adjust_bank(
    v_token,
    10,
    'Aumentar banca com Aviator aberto',
    'live-bank-plus-'||gen_random_uuid()::text
  );

  if round((v_result->>'balance')::numeric,2)<>110 then
    raise exception 'aumento da banca com Aviator aberto falhou: %',v_result;
  end if;

  v_result:=public.jl_aviator_admin_adjust_bank(
    v_token,
    -5,
    'Reduzir valor livre com Aviator aberto',
    'live-bank-minus-'||gen_random_uuid()::text
  );

  if round((v_result->>'balance')::numeric,2)<>105 then
    raise exception 'redução livre da banca com Aviator aberto falhou: %',v_result;
  end if;

  select balance into v_balance
  from public.jl_aviator_bank
  where id=true;

  if round(v_balance,2)<>105 then
    raise exception 'saldo final inesperado: %',v_balance;
  end if;

  -- Regressão do erro observado em produção:
  -- "record r has no field round_id".
  v_state:=public.jl_aviator_admin_state(v_token);

  if (v_state->'round'->>'id')::bigint<>v_round then
    raise exception 'estado administrativo não devolveu a rodada correta: %',v_state;
  end if;

  if round((v_state->'bank'->>'balance')::numeric,2)<>105 then
    raise exception 'estado administrativo não devolveu a banca correta: %',v_state;
  end if;
end
$live_bank$;

rollback;

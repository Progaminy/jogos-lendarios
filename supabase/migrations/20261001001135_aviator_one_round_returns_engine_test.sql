CREATE OR REPLACE FUNCTION public.jl_aviator_admin_start_one_round_test(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_live integer;
  v_bank numeric;
  v_enabled boolean;
  v_test boolean;
  v_admin uuid:=public.jl_admin_account_id(p_token);
  v_before jsonb;
  v_after jsonb;
  v_preflight jsonb;
begin
  if v_admin is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  perform pg_advisory_xact_lock(hashtext('jl_aviator_engine_tick'));
  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));

  select enabled,one_round_test,
         jsonb_build_object(
           'enabled',coalesce(enabled,true),
           'one_round_test',coalesce(one_round_test,false)
         )
    into v_enabled,v_test,v_before
  from public.jl_aviator_settings
  where id=true
  for update;

  if coalesce(v_enabled,false) or coalesce(v_test,false) then
    raise exception 'Feche o Aviator antes de iniciar uma rodada de teste.';
  end if;

  select count(*)
    into v_live
  from public.jl_aviator_rounds
  where status in ('OPEN','LOCKED','FLYING','CRASHED');

  if v_live<>0 then
    raise exception 'Existe uma rodada Aviator em andamento.';
  end if;

  v_preflight:=public.jl_aviator_admin_engine_preflight(p_token);

  if coalesce((v_preflight->>'ok')::boolean,false) is distinct from true then
    raise exception 'Testes automáticos do motor falharam: %',
      coalesce(v_preflight->'failed_checks','[]'::jsonb)::text;
  end if;

  select balance
    into v_bank
  from public.jl_aviator_bank
  where id=true
  for update;

  update public.jl_aviator_settings
     set enabled=true,
         one_round_test=true,
         updated_at=clock_timestamp()
   where id=true;

  v_after:=jsonb_build_object(
    'enabled',true,
    'one_round_test',true,
    'bank_balance',v_bank,
    'engine_test',v_preflight
  );

  insert into public.audit_log(
    action,
    details,
    actor_admin_id,
    actor_session_id,
    actor_name,
    actor_role,
    target_type,
    target_id,
    before_state,
    after_state
  )
  values(
    'aviator.admin.one_round_test_started',
    jsonb_build_object(
      'bankBalance',v_bank,
      'startedAt',clock_timestamp()
    ),
    v_admin,
    nullif(current_setting('jl.admin_session_id',true),'')::uuid,
    nullif(current_setting('jl.admin_name',true),''),
    nullif(current_setting('jl.admin_role',true),''),
    'aviator_settings',
    'global',
    v_before,
    v_after
  );

  return jsonb_build_object(
    'ok',true,
    'enabled',true,
    'one_round_test',true,
    'bank_balance',v_bank,
    'engine_test',v_preflight
  );
end
$function$;
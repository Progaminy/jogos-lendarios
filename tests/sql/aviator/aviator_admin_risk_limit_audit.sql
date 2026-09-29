begin;

do $setup$
declare
  v_admin uuid;
  v_token text:='risk-audit-'||gen_random_uuid()::text;
  v_session uuid;
  v_old numeric;
  v_new numeric;
begin
  insert into public.admin_accounts(
    display_name,role,code_hash,code_scheme,active
  )
  values('RISK LIMIT AUDIT TEST','admin','test-hash','bcrypt',true)
  returning id into v_admin;

  insert into public.admin_sessions(admin_id,token_hash,expires_at)
  values(
    v_admin,
    public.jl_token_hash(v_token),
    clock_timestamp()+interval '1 hour'
  )
  returning id into v_session;

  perform public.jl_admin_account_id(v_token);

  select exposure_ratio into v_old
  from public.jl_aviator_bank
  where id=true;

  v_new:=case when v_old<=0.45 then 0.55 else 0.45 end;

  update public.jl_aviator_bank
     set exposure_ratio=v_new,
         updated_at=clock_timestamp()
   where id=true;

  if not exists(
    select 1
    from public.audit_log
    where action='aviator.admin.risk_limit_changed'
      and actor_admin_id=v_admin
      and actor_session_id=v_session
      and actor_name='RISK LIMIT AUDIT TEST'
      and actor_role='admin'
      and target_type='aviator_bank'
      and target_id='global'
      and (before_state->>'exposure_ratio')::numeric=v_old
      and (after_state->>'exposure_ratio')::numeric=v_new
      and details->>'field'='exposure_ratio'
  ) then
    raise exception 'alteração do limite de risco não foi auditada corretamente';
  end if;
end
$setup$;

rollback;

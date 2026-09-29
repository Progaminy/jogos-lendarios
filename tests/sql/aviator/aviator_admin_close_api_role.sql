begin;

do $api_close_setup$
declare
  v_admin uuid;
  v_token text:='api-close-'||gen_random_uuid()::text;
begin
  insert into public.admin_accounts(
    display_name,role,code_hash,code_scheme,active
  )
  values(
    'AVIATOR API CLOSE TEST',
    'admin',
    'test-hash',
    'bcrypt',
    true
  )
  returning id into v_admin;

  insert into public.admin_sessions(
    admin_id,token_hash,expires_at
  )
  values(
    v_admin,
    public.jl_token_hash(v_token),
    clock_timestamp()+interval '10 minutes'
  );

  perform set_config('jl.api_close_token',v_token,true);
end
$api_close_setup$;

set local role anon;

select public.jl_aviator_admin_close(
  current_setting('jl.api_close_token',true)
);

reset role;

do $verify$
declare
  v_enabled boolean;
begin
  select enabled
    into v_enabled
  from public.jl_aviator_settings
  where id=true;

  if v_enabled is distinct from false then
    raise exception 'anon API admin close did not set enabled=false';
  end if;
end
$verify$;

rollback;

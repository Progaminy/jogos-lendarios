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

do $audit_setup$
declare
  v_admin uuid;
  v_token text:='audit-admin-'||gen_random_uuid()::text;
  v_session uuid;
  v_round bigint;
  v_request_key text:='audit-bank-'||gen_random_uuid()::text;
begin
  insert into public.admin_accounts(
    display_name,role,code_hash,code_scheme,active
  )
  values(
    'AVIATOR AUDIT TEST',
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
    clock_timestamp()+interval '1 hour'
  )
  returning id into v_session;

  perform set_config('jl.audit_token',v_token,true);
  perform set_config('jl.audit_admin',v_admin::text,true);
  perform set_config('jl.audit_session',v_session::text,true);
  perform set_config('jl.audit_request',v_request_key,true);

  perform public.jl_aviator_admin_reopen(v_token);
  perform public.jl_aviator_admin_close(v_token);

  perform public.jl_aviator_admin_adjust_bank(
    v_token,
    1.00,
    'Teste de auditoria da banca',
    v_request_key
  );

  perform public.jl_aviator_admin_start_one_round_test(v_token);

  -- Voltar ao modo fechado para isolar o teste de cancelamento.
  update public.jl_aviator_settings
     set enabled=false,
         one_round_test=false,
         updated_at=clock_timestamp()
   where id=true;

  insert into public.jl_aviator_rounds(
    status,
    betting_closes_at,
    takeoff_at
  )
  values(
    'OPEN',
    clock_timestamp()+interval '30 seconds',
    clock_timestamp()+interval '33 seconds'
  )
  returning id into v_round;

  perform set_config('jl.audit_round',v_round::text,true);

  perform public.jl_aviator_admin_cancel_round(
    v_token,
    v_round,
    'Teste de auditoria do cancelamento'
  );
end
$audit_setup$;

do $audit_verify$
declare
  v_admin uuid:=current_setting('jl.audit_admin',true)::uuid;
  v_session uuid:=current_setting('jl.audit_session',true)::uuid;
  v_round bigint:=current_setting('jl.audit_round',true)::bigint;
  v_missing integer;
begin
  select count(*)
    into v_missing
  from (
    values
      ('aviator.admin.reopened'::text,'aviator_settings'::text,'global'::text),
      ('aviator.admin.closed'::text,'aviator_settings'::text,'global'::text),
      ('aviator.admin.bank_adjusted'::text,'aviator_bank'::text,'global'::text),
      ('aviator.admin.one_round_test_started'::text,'aviator_settings'::text,'global'::text),
      ('aviator.round_admin_cancelled'::text,'aviator_round'::text,v_round::text)
  ) expected(action,target_type,target_id)
  where not exists(
    select 1
    from public.audit_log a
    where a.action=expected.action
      and a.target_type=expected.target_type
      and a.target_id=expected.target_id
      and a.actor_admin_id=v_admin
      and a.actor_session_id=v_session
      and a.actor_name='AVIATOR AUDIT TEST'
      and a.actor_role='admin'
      and a.before_state is not null
      and a.after_state is not null
  );

  if v_missing<>0 then
    raise exception 'faltam % eventos administrativos estruturados',v_missing;
  end if;

  if not exists(
    select 1
    from public.audit_log
    where action='aviator.admin.reopened'
      and actor_admin_id=v_admin
      and (before_state->>'enabled')::boolean=false
      and (after_state->>'enabled')::boolean=true
  ) then
    raise exception 'reabertura sem before/after correto';
  end if;

  if not exists(
    select 1
    from public.audit_log
    where action='aviator.admin.closed'
      and actor_admin_id=v_admin
      and (before_state->>'enabled')::boolean=true
      and (after_state->>'enabled')::boolean=false
  ) then
    raise exception 'fecho sem before/after correto';
  end if;

  if not exists(
    select 1
    from public.audit_log
    where action='aviator.admin.bank_adjusted'
      and actor_admin_id=v_admin
      and details->>'reason'='Teste de auditoria da banca'
      and (after_state->>'balance')::numeric-(before_state->>'balance')::numeric=1
  ) then
    raise exception 'ajuste da banca sem motivo ou before/after correto';
  end if;

  if not exists(
    select 1
    from public.audit_log
    where action='aviator.round_admin_cancelled'
      and actor_admin_id=v_admin
      and details->>'reason'='Teste de auditoria do cancelamento'
      and after_state->>'status'='CANCELLED'
  ) then
    raise exception 'cancelamento sem motivo auditado';
  end if;
end
$audit_verify$;

set local role anon;

select count(*) as visible_admin_events
from public.jl_aviator_admin_audit_history(
  current_setting('jl.audit_token',true),
  40
);

reset role;

rollback;

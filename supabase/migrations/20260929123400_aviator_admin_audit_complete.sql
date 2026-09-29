-- Aviator: auditoria administrativa completa e consultável no painel.

create index if not exists audit_log_action_created_idx
on public.audit_log(action,created_at desc);

create or replace function public.jl_aviator_admin_set_enabled(
  p_token text,
  p_enabled boolean
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  s public.jl_aviator_settings;
  v_admin uuid:=public.jl_admin_account_id(p_token);
  v_resolution jsonb:=jsonb_build_object('action','NONE');
  v_before jsonb;
  v_after jsonb;
  v_action text;
begin
  if v_admin is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  if p_enabled is null then
    raise exception 'Estado de manutencao invalido.';
  end if;

  perform pg_advisory_xact_lock(hashtext('jl_aviator_engine_tick'));
  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));

  select jsonb_build_object(
    'enabled',coalesce(enabled,true),
    'one_round_test',coalesce(one_round_test,false),
    'maintenance_message',coalesce(maintenance_message,'Aviator brevemente.')
  )
  into v_before
  from public.jl_aviator_settings
  where id=true
  for update;

  v_before:=coalesce(
    v_before,
    jsonb_build_object(
      'enabled',true,
      'one_round_test',false,
      'maintenance_message','Aviator brevemente.'
    )
  );

  insert into public.jl_aviator_settings(
    id,enabled,one_round_test,maintenance_message,updated_at
  )
  values(
    true,p_enabled,false,'Aviator brevemente.',clock_timestamp()
  )
  on conflict(id) do update
    set enabled=excluded.enabled,
        one_round_test=false,
        maintenance_message='Aviator brevemente.',
        updated_at=excluded.updated_at
  returning * into s;

  if not p_enabled then
    v_resolution:=public.jl_aviator_engine_tick();
  end if;

  v_after:=jsonb_build_object(
    'enabled',s.enabled,
    'one_round_test',coalesce(s.one_round_test,false),
    'maintenance_message',coalesce(s.maintenance_message,'Aviator brevemente.'),
    'updated_at',s.updated_at
  );

  v_action:=case
    when p_enabled then 'aviator.admin.reopened'
    else 'aviator.admin.closed'
  end;

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
    v_action,
    jsonb_build_object(
      'resolution',v_resolution,
      'source','admin_panel'
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
    'enabled',s.enabled,
    'one_round_test',false,
    'maintenance_message','Aviator brevemente.',
    'resolution',v_resolution
  );
end
$$;

revoke all on function public.jl_aviator_admin_set_enabled(text,boolean)
from public;
grant execute on function public.jl_aviator_admin_set_enabled(text,boolean)
to anon,authenticated;

create or replace function public.jl_aviator_admin_start_one_round_test(
  p_token text
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_live integer;
  v_bank numeric;
  v_enabled boolean;
  v_test boolean;
  v_admin uuid:=public.jl_admin_account_id(p_token);
  v_before jsonb;
  v_after jsonb;
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
    'bank_balance',v_bank
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
    'bank_balance',v_bank
  );
end
$$;

revoke all on function public.jl_aviator_admin_start_one_round_test(text)
from public;
grant execute on function public.jl_aviator_admin_start_one_round_test(text)
to anon,authenticated;

create or replace function public.jl_aviator_admin_adjust_bank(
  p_token text,
  p_delta numeric,
  p_reason text,
  p_request_key text
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  b public.jl_aviator_bank;
  l public.jl_aviator_bank_ledger;
  v_admin uuid:=public.jl_admin_account_id(p_token);
  v_before jsonb;
  v_after jsonb;
  v_reason text:=left(trim(coalesce(p_reason,'')),160);
begin
  if v_admin is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  if p_request_key is null
     or length(trim(p_request_key))<8
     or length(p_request_key)>100 then
    raise exception 'Chave do ajuste invalida';
  end if;

  perform pg_advisory_xact_lock(hashtext('jl_aviator_bank_adjust'));

  select *
    into l
  from public.jl_aviator_bank_ledger
  where request_key=p_request_key;

  if l.id is not null then
    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'balance',l.balance_after
    );
  end if;

  if p_delta is null or p_delta=0 or abs(p_delta)>100000000 then
    raise exception 'Ajuste invalido';
  end if;

  if length(v_reason)<3 then
    raise exception 'Informe o motivo';
  end if;

  if p_delta<0 and exists(
    select 1
    from public.jl_aviator_rounds
    where status in ('LOCKED','FLYING')
  ) then
    raise exception 'Nao e permitido retirar fundos da banca durante exposicao financeira ativa';
  end if;

  select *
    into b
  from public.jl_aviator_bank
  where id=true
  for update;

  v_before:=jsonb_build_object(
    'balance',b.balance,
    'exposure_ratio',b.exposure_ratio
  );

  if b.balance+p_delta<0 then
    raise exception 'Ajuste deixaria a banca negativa';
  end if;

  update public.jl_aviator_bank
     set balance=round(balance+p_delta,2),
         updated_at=now()
   where id=true
  returning * into b;

  insert into public.jl_aviator_bank_ledger(
    delta,balance_after,reason,request_key
  )
  values(
    round(p_delta,2),
    b.balance,
    v_reason,
    p_request_key
  );

  v_after:=jsonb_build_object(
    'balance',b.balance,
    'exposure_ratio',b.exposure_ratio
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
    'aviator.admin.bank_adjusted',
    jsonb_build_object(
      'delta',round(p_delta,2),
      'reason',v_reason,
      'requestKey',p_request_key
    ),
    v_admin,
    nullif(current_setting('jl.admin_session_id',true),'')::uuid,
    nullif(current_setting('jl.admin_name',true),''),
    nullif(current_setting('jl.admin_role',true),''),
    'aviator_bank',
    'global',
    v_before,
    v_after
  );

  return jsonb_build_object(
    'ok',true,
    'already_processed',false,
    'balance',b.balance
  );
end
$$;

revoke all on function public.jl_aviator_admin_adjust_bank(text,numeric,text,text)
from public;
grant execute on function public.jl_aviator_admin_adjust_bank(text,numeric,text,text)
to anon,authenticated;

create or replace function public.jl_aviator_admin_adjust_bank(
  p_token text,
  p_delta numeric,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_request_key text:=
    'legacy-admin-adjust:'||gen_random_uuid()::text;
begin
  return public.jl_aviator_admin_adjust_bank(
    p_token,
    p_delta,
    p_reason,
    v_request_key
  );
end
$$;

revoke all on function public.jl_aviator_admin_adjust_bank(text,numeric,text)
from public;
grant execute on function public.jl_aviator_admin_adjust_bank(text,numeric,text)
to anon,authenticated;

create or replace function public.jl_aviator_admin_audit_history(
  p_token text,
  p_limit integer default 40
)
returns table(
  id uuid,
  created_at timestamptz,
  action text,
  actor_admin_id uuid,
  actor_session_id uuid,
  actor_name text,
  actor_role text,
  target_type text,
  target_id text,
  details jsonb,
  before_state jsonb,
  after_state jsonb
)
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
begin
  perform public.jl_require_admin(p_token);

  return query
  select
    a.id,
    a.created_at,
    a.action,
    a.actor_admin_id,
    a.actor_session_id,
    a.actor_name,
    a.actor_role,
    a.target_type,
    a.target_id,
    a.details,
    a.before_state,
    a.after_state
  from public.audit_log a
  where a.action like 'aviator.%'
    and a.actor_admin_id is not null
  order by a.created_at desc
  limit least(greatest(coalesce(p_limit,40),1),100);
end
$$;

revoke all on function public.jl_aviator_admin_audit_history(text,integer)
from public;
grant execute on function public.jl_aviator_admin_audit_history(text,integer)
to anon,authenticated;

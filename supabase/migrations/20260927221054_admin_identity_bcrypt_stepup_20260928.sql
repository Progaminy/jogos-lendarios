-- Ponto 7 — autenticação administrativa.
-- Mantém token aleatório e sessão de 12h.
-- Adiciona identidades/roles de administradores, bcrypt, sessão ligada ao admin
-- e reautenticação recente para ações financeiras/destrutivas.
-- A credencial SHA-256 existente é migrada para bcrypt no primeiro uso válido.

create table if not exists public.admin_accounts (
  id uuid primary key default extensions.gen_random_uuid(),
  display_name text not null,
  role text not null check (role in ('admin','super_admin')),
  code_hash text,
  legacy_sha256_hash text,
  is_primary boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_login_at timestamptz,
  check (code_hash is not null or legacy_sha256_hash is not null)
);

alter table public.admin_accounts enable row level security;
revoke all privileges on table public.admin_accounts from public, anon, authenticated;
grant select, insert, update, delete on table public.admin_accounts to service_role;

create unique index if not exists admin_accounts_one_primary_idx
  on public.admin_accounts ((is_primary))
  where is_primary;

insert into public.admin_accounts(
  display_name, role, code_hash, legacy_sha256_hash, is_primary, active
)
select
  'Administrador principal',
  'super_admin',
  case when c.code_hash like '$2%' then c.code_hash else null end,
  case when c.code_hash like '$2%' then null else c.code_hash end,
  true,
  true
from public.admin_config c
where not exists (select 1 from public.admin_accounts)
order by c.id
limit 1;

alter table public.admin_sessions
  add column if not exists admin_id uuid,
  add column if not exists elevated_until timestamptz,
  add column if not exists ip_address text,
  add column if not exists user_agent text;

update public.admin_sessions
set admin_id = (
  select id from public.admin_accounts
  where is_primary
  order by created_at
  limit 1
)
where admin_id is null;

update public.admin_sessions
set elevated_until = least(expires_at, now() + interval '10 minutes')
where elevated_until is null
  and expires_at > now();

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname='admin_sessions_admin_id_fkey'
      and conrelid='public.admin_sessions'::regclass
  ) then
    alter table public.admin_sessions
      add constraint admin_sessions_admin_id_fkey
      foreign key (admin_id) references public.admin_accounts(id);
  end if;
end
$$;

delete from public.admin_sessions where admin_id is null;
alter table public.admin_sessions alter column admin_id set not null;

create index if not exists admin_sessions_admin_id_idx
  on public.admin_sessions(admin_id);

create or replace function public.jl_admin_verify_account_code(
  p_admin_id uuid,
  p_code text
)
returns boolean
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  a public.admin_accounts%rowtype;
  v_sha text;
  v_new_hash text;
begin
  select * into a
  from public.admin_accounts
  where id=p_admin_id
  for update;

  if a.id is null or not a.active then
    return false;
  end if;

  if a.code_hash is not null
     and a.code_hash like '$2%'
     and extensions.crypt(coalesce(p_code,''), a.code_hash)=a.code_hash then
    return true;
  end if;

  if a.legacy_sha256_hash is not null then
    v_sha:=encode(extensions.digest(coalesce(p_code,''),'sha256'),'hex');
    if v_sha=a.legacy_sha256_hash then
      v_new_hash:=extensions.crypt(coalesce(p_code,''),extensions.gen_salt('bf',12));
      update public.admin_accounts
      set code_hash=v_new_hash,
          legacy_sha256_hash=null,
          updated_at=now()
      where id=a.id;

      if a.is_primary then
        update public.admin_config
        set code_hash=v_new_hash,
            updated_at=now();
      end if;
      return true;
    end if;
  end if;

  return false;
end;
$function$;

revoke all on function public.jl_admin_verify_account_code(uuid,text)
from public, anon, authenticated;

create or replace function public.jl_admin_account_id(p_token text)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_admin uuid;
begin
  delete from public.admin_sessions where expires_at<=now();

  select s.admin_id into v_admin
  from public.admin_sessions s
  join public.admin_accounts a on a.id=s.admin_id and a.active
  where s.token_hash=public.jl_token_hash(p_token)
    and s.expires_at>now()
  limit 1;

  return v_admin;
end;
$function$;

revoke all on function public.jl_admin_account_id(text)
from public, anon, authenticated;

create or replace function public.jl_admin_ok(p_token text)
returns boolean
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
begin
  return public.jl_admin_account_id(p_token) is not null;
end;
$function$;

create or replace function public.jl_require_admin(p_token text)
returns void
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
begin
  if public.jl_admin_account_id(p_token) is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;
end;
$function$;

create or replace function public.jl_require_super_admin(p_token text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_admin uuid:=public.jl_admin_account_id(p_token);
  v_role text;
begin
  if v_admin is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  select role into v_role
  from public.admin_accounts
  where id=v_admin and active;

  if v_role<>'super_admin' then
    raise exception 'Ação permitida apenas ao super administrador.';
  end if;
end;
$function$;

revoke all on function public.jl_require_super_admin(text)
from public, anon, authenticated;

create or replace function public.jl_require_admin_elevated(p_token text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_ok boolean;
begin
  select exists(
    select 1
    from public.admin_sessions s
    join public.admin_accounts a on a.id=s.admin_id and a.active
    where s.token_hash=public.jl_token_hash(p_token)
      and s.expires_at>now()
      and s.elevated_until>now()
  ) into v_ok;

  if not v_ok then
    raise exception 'REAUTH_REQUIRED: Confirme novamente o código administrativo para continuar.';
  end if;
end;
$function$;

revoke all on function public.jl_require_admin_elevated(text)
from public, anon, authenticated;

create or replace function public.jl_admin_verify_code_for_token(
  p_token text,
  p_code text
)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_admin uuid:=public.jl_admin_account_id(p_token);
begin
  if v_admin is null then
    return false;
  end if;
  return public.jl_admin_verify_account_code(v_admin,p_code);
end;
$function$;

revoke all on function public.jl_admin_verify_code_for_token(text,text)
from public, anon, authenticated;

create or replace function public.jl_admin_login(p_code text)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_admin public.admin_accounts%rowtype;
  v_candidate uuid;
  v_token text;
  v_headers jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  v_ip text;
  v_country text;
  v_agent text;
  v_source text;
  v_key text;
  v_rate public.login_rate_limits%rowtype;
  v_failed integer;
  v_level integer;
  v_minutes integer;
  v_retry integer;
  v_unseen integer := 0;
  v_last_alert public.admin_login_alerts%rowtype;
  v_sha text;
begin
  v_ip := nullif(btrim(split_part(coalesce(v_headers->>'x-forwarded-for',''), ',', 1)), '');
  if v_ip is null then v_ip := nullif(v_headers->>'cf-connecting-ip',''); end if;
  if v_ip is null then v_ip := nullif(v_headers->>'x-real-ip',''); end if;

  v_country := coalesce(
    nullif(v_headers->>'cf-ipcountry',''),
    nullif(v_headers->>'x-vercel-ip-country',''),
    nullif(v_headers->>'x-country-code','')
  );
  v_agent := nullif(v_headers->>'user-agent','');
  v_source := coalesce(v_ip,v_agent,'unknown');
  v_key := encode(extensions.digest(v_source,'sha256'),'hex');

  insert into public.login_rate_limits(scope,subject_key)
  values('admin',v_key)
  on conflict(scope,subject_key) do nothing;

  select * into v_rate
  from public.login_rate_limits
  where scope='admin' and subject_key=v_key
  for update;

  if v_rate.last_failed_at is not null
     and v_rate.last_failed_at < now()-interval '24 hours'
     and coalesce(v_rate.blocked_until,'-infinity'::timestamptz)<=now() then
    update public.login_rate_limits
    set failed_attempts=0,block_level=0,blocked_until=null,updated_at=now()
    where scope='admin' and subject_key=v_key;
    v_rate.failed_attempts:=0;
    v_rate.block_level:=0;
    v_rate.blocked_until:=null;
  end if;

  if v_rate.blocked_until is not null and v_rate.blocked_until>now() then
    v_retry:=greatest(1,ceil(extract(epoch from (v_rate.blocked_until-now()))/60.0)::integer);
    perform set_config('response.status','429',true);
    return jsonb_build_object(
      'ok',false,
      'message',format('Acesso administrativo temporariamente limitado. Tente novamente em %s minuto(s).',v_retry),
      'retry_after_minutes',v_retry
    );
  end if;

  v_sha:=encode(extensions.digest(coalesce(p_code,''),'sha256'),'hex');

  select id into v_candidate
  from public.admin_accounts
  where active and legacy_sha256_hash=v_sha
  order by is_primary desc,created_at
  limit 1;

  if v_candidate is null then
    for v_admin in
      select *
      from public.admin_accounts
      where active and code_hash is not null
      order by is_primary desc,created_at
    loop
      if extensions.crypt(coalesce(p_code,''),v_admin.code_hash)=v_admin.code_hash then
        v_candidate:=v_admin.id;
        exit;
      end if;
    end loop;
  end if;

  if v_candidate is null or not public.jl_admin_verify_account_code(v_candidate,p_code) then
    v_failed:=coalesce(v_rate.failed_attempts,0)+1;

    if v_failed>=3 then
      v_level:=coalesce(v_rate.block_level,0)+1;
      v_minutes:=case v_level
        when 1 then 15
        when 2 then 30
        when 3 then 60
        when 4 then 120
        when 5 then 240
        when 6 then 480
        when 7 then 960
        else 1440
      end;

      update public.login_rate_limits
      set failed_attempts=0,
          block_level=v_level,
          blocked_until=now()+make_interval(mins=>v_minutes),
          last_failed_at=now(),
          updated_at=now()
      where scope='admin' and subject_key=v_key;

      insert into public.admin_login_alerts(
        failed_attempts,block_level,blocked_until,ip_address,country_code,user_agent
      ) values(
        3,v_level,now()+make_interval(mins=>v_minutes),v_ip,v_country,v_agent
      );

      insert into public.audit_log(action,details)
      values('admin_login_rate_limited',jsonb_build_object(
        'failed_attempts',3,
        'block_level',v_level,
        'blocked_minutes',v_minutes,
        'ip_address',v_ip,
        'country_code',v_country,
        'user_agent',v_agent
      ));

      perform set_config('response.status','429',true);
      return jsonb_build_object(
        'ok',false,
        'message',format('Acesso administrativo temporariamente limitado. Tente novamente em %s minuto(s).',v_minutes),
        'retry_after_minutes',v_minutes
      );
    end if;

    update public.login_rate_limits
    set failed_attempts=v_failed,last_failed_at=now(),updated_at=now()
    where scope='admin' and subject_key=v_key;

    perform set_config('response.status','401',true);
    return jsonb_build_object(
      'ok',false,
      'message','Código administrativo incorreto.',
      'attempts_remaining',3-v_failed
    );
  end if;

  select * into v_admin
  from public.admin_accounts
  where id=v_candidate and active;

  delete from public.login_rate_limits
  where scope='admin' and subject_key=v_key;

  select count(*)::integer into v_unseen
  from public.admin_login_alerts
  where seen_at is null;

  if v_unseen>0 then
    select * into v_last_alert
    from public.admin_login_alerts
    where seen_at is null
    order by created_at desc
    limit 1;

    update public.admin_login_alerts
    set seen_at=now()
    where seen_at is null;
  end if;

  v_token:=encode(extensions.gen_random_bytes(32),'hex');

  insert into public.admin_sessions(
    admin_id,token_hash,expires_at,elevated_until,ip_address,user_agent
  ) values(
    v_admin.id,
    public.jl_token_hash(v_token),
    now()+interval '12 hours',
    now()+interval '10 minutes',
    v_ip,
    v_agent
  );

  update public.admin_accounts
  set last_login_at=now(),updated_at=now()
  where id=v_admin.id;

  return jsonb_build_object(
    'ok',true,
    'token',v_token,
    'expires_in_hours',12,
    'elevated_for_minutes',10,
    'admin',jsonb_build_object(
      'id',v_admin.id,
      'name',v_admin.display_name,
      'role',v_admin.role
    ),
    'security_alert',
      case when v_unseen>0 then jsonb_build_object(
        'count',v_unseen,
        'created_at',v_last_alert.created_at,
        'ip_address',v_last_alert.ip_address,
        'country_code',v_last_alert.country_code,
        'failed_attempts',v_last_alert.failed_attempts,
        'blocked_until',v_last_alert.blocked_until
      ) else null end
  );
end;
$function$;

create or replace function public.jl_admin_session_info(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r record;
begin
  select s.expires_at,s.elevated_until,a.id,a.display_name,a.role
  into r
  from public.admin_sessions s
  join public.admin_accounts a on a.id=s.admin_id and a.active
  where s.token_hash=public.jl_token_hash(p_token)
    and s.expires_at>now()
  limit 1;

  if r.id is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  return jsonb_build_object(
    'id',r.id,
    'name',r.display_name,
    'role',r.role,
    'expires_at',r.expires_at,
    'elevated_until',r.elevated_until,
    'elevated',coalesce(r.elevated_until>now(),false)
  );
end;
$function$;

create or replace function public.jl_admin_reauthenticate(
  p_token text,
  p_code text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_admin uuid:=public.jl_admin_account_id(p_token);
  v_until timestamptz;
begin
  if v_admin is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  if not public.jl_admin_verify_account_code(v_admin,p_code) then
    raise exception 'Código administrativo incorreto.';
  end if;

  v_until:=now()+interval '10 minutes';

  update public.admin_sessions
  set elevated_until=v_until
  where token_hash=public.jl_token_hash(p_token)
    and admin_id=v_admin
    and expires_at>now();

  return jsonb_build_object(
    'ok',true,
    'elevated_until',v_until,
    'message','Autenticação reforçada confirmada por 10 minutos.'
  );
end;
$function$;

create or replace function public.jl_admin_list_accounts(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  perform public.jl_require_super_admin(p_token);

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',id,
      'name',display_name,
      'role',role,
      'active',active,
      'is_primary',is_primary,
      'created_at',created_at,
      'updated_at',updated_at,
      'last_login_at',last_login_at
    ) order by is_primary desc,created_at)
    from public.admin_accounts
  ),'[]'::jsonb);
end;
$function$;

create or replace function public.jl_admin_create_account(
  p_token text,
  p_display_name text,
  p_role text,
  p_code text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_name text:=regexp_replace(trim(coalesce(p_display_name,'')),'[[:space:]]+',' ','g');
  v_role text:=lower(trim(coalesce(p_role,'')));
  a record;
  v_id uuid;
begin
  perform public.jl_require_super_admin(p_token);
  perform public.jl_require_admin_elevated(p_token);

  if char_length(v_name)<2 or char_length(v_name)>80 then
    raise exception 'O nome do administrador deve ter entre 2 e 80 caracteres.';
  end if;
  if v_role not in ('admin','super_admin') then
    raise exception 'Função administrativa inválida.';
  end if;
  if char_length(coalesce(p_code,''))<6 or char_length(p_code)>64 then
    raise exception 'O código administrativo deve ter entre 6 e 64 caracteres.';
  end if;

  for a in select id,code_hash,legacy_sha256_hash from public.admin_accounts where active loop
    if (a.code_hash is not null and extensions.crypt(p_code,a.code_hash)=a.code_hash)
       or (a.legacy_sha256_hash is not null and encode(extensions.digest(p_code,'sha256'),'hex')=a.legacy_sha256_hash) then
      raise exception 'Este código já pertence a outro administrador.';
    end if;
  end loop;

  insert into public.admin_accounts(display_name,role,code_hash,active)
  values(v_name,v_role,extensions.crypt(p_code,extensions.gen_salt('bf',12)),true)
  returning id into v_id;

  return jsonb_build_object(
    'ok',true,
    'id',v_id,
    'name',v_name,
    'role',v_role
  );
end;
$function$;

create or replace function public.jl_admin_set_account_active(
  p_token text,
  p_admin_id uuid,
  p_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_me uuid:=public.jl_admin_account_id(p_token);
  v_target public.admin_accounts%rowtype;
begin
  perform public.jl_require_super_admin(p_token);
  perform public.jl_require_admin_elevated(p_token);

  select * into v_target
  from public.admin_accounts
  where id=p_admin_id
  for update;

  if v_target.id is null then
    raise exception 'Administrador não encontrado.';
  end if;
  if v_target.id=v_me and not p_active then
    raise exception 'Não pode desativar a própria conta administrativa.';
  end if;
  if v_target.role='super_admin' and not p_active and not exists(
    select 1 from public.admin_accounts
    where active and role='super_admin' and id<>v_target.id
  ) then
    raise exception 'Não pode desativar o último super administrador.';
  end if;

  update public.admin_accounts
  set active=p_active,updated_at=now()
  where id=v_target.id;

  if not p_active then
    delete from public.admin_sessions where admin_id=v_target.id;
  end if;

  return jsonb_build_object('ok',true,'id',v_target.id,'active',p_active);
end;
$function$;

create or replace function public.jl_admin_change_own_code(
  p_token text,
  p_current_code text,
  p_new_code text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_me uuid:=public.jl_admin_account_id(p_token);
  v_primary boolean:=false;
  a record;
  v_hash text;
begin
  if v_me is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  if not public.jl_admin_verify_account_code(v_me,p_current_code) then
    raise exception 'Código administrativo atual incorreto.';
  end if;

  if char_length(coalesce(p_new_code,''))<6 or char_length(p_new_code)>64 then
    raise exception 'O novo código administrativo deve ter entre 6 e 64 caracteres.';
  end if;
  if p_new_code=p_current_code then
    raise exception 'O novo código deve ser diferente do atual.';
  end if;

  for a in select id,code_hash,legacy_sha256_hash from public.admin_accounts where active and id<>v_me loop
    if (a.code_hash is not null and extensions.crypt(p_new_code,a.code_hash)=a.code_hash)
       or (a.legacy_sha256_hash is not null and encode(extensions.digest(p_new_code,'sha256'),'hex')=a.legacy_sha256_hash) then
      raise exception 'Este código já pertence a outro administrador.';
    end if;
  end loop;

  v_hash:=extensions.crypt(p_new_code,extensions.gen_salt('bf',12));

  update public.admin_accounts
  set code_hash=v_hash,legacy_sha256_hash=null,updated_at=now()
  where id=v_me
  returning is_primary into v_primary;

  if v_primary then
    update public.admin_config
    set code_hash=v_hash,updated_at=now();
  end if;

  update public.admin_sessions
  set elevated_until=now()+interval '10 minutes'
  where admin_id=v_me and token_hash=public.jl_token_hash(p_token);

  return jsonb_build_object('ok',true,'message','Código administrativo alterado com segurança.');
end;
$function$;

revoke all on function public.jl_admin_login(text) from public, anon, authenticated;
grant execute on function public.jl_admin_login(text) to anon, authenticated, service_role;

revoke all on function public.jl_admin_ok(text) from public, anon, authenticated;
grant execute on function public.jl_admin_ok(text) to anon, authenticated, service_role;

revoke all on function public.jl_admin_session_info(text) from public, anon, authenticated;
grant execute on function public.jl_admin_session_info(text) to anon, authenticated, service_role;

revoke all on function public.jl_admin_reauthenticate(text,text) from public, anon, authenticated;
grant execute on function public.jl_admin_reauthenticate(text,text) to anon, authenticated, service_role;

revoke all on function public.jl_admin_list_accounts(text) from public, anon, authenticated;
grant execute on function public.jl_admin_list_accounts(text) to anon, authenticated, service_role;

revoke all on function public.jl_admin_create_account(text,text,text,text) from public, anon, authenticated;
grant execute on function public.jl_admin_create_account(text,text,text,text) to anon, authenticated, service_role;

revoke all on function public.jl_admin_set_account_active(text,uuid,boolean) from public, anon, authenticated;
grant execute on function public.jl_admin_set_account_active(text,uuid,boolean) to anon, authenticated, service_role;

revoke all on function public.jl_admin_change_own_code(text,text,text) from public, anon, authenticated;
grant execute on function public.jl_admin_change_own_code(text,text,text) to anon, authenticated, service_role;

do $$
declare
  v_sig regprocedure;
  v_def text;
begin
  foreach v_sig in array array[
    'public.jl_admin_review_deposit(text,uuid,text)'::regprocedure,
    'public.jl_admin_review_withdrawal(text,uuid,text)'::regprocedure,
    'public.jl_admin_adjust_balance(text,uuid,numeric,text)'::regprocedure,
    'public.jl_admin_set_blocked(text,uuid,boolean)'::regprocedure
  ]
  loop
    select pg_get_functiondef(v_sig) into v_def;
    if position('perform public.jl_require_admin(p_token);' in v_def)>0 then
      v_def:=replace(
        v_def,
        'perform public.jl_require_admin(p_token);',
        'perform public.jl_require_admin_elevated(p_token);'
      );
      execute v_def;
    end if;
  end loop;
end
$$;

do $$
declare
  v_sig regprocedure;
  v_def text;
  v_old text := 'if not public.jl_admin_ok(p_token) then' || E'\n' ||
                '    raise exception ''Sessão administrativa inválida ou expirada.'';' || E'\n' ||
                '  end if;';
begin
  foreach v_sig in array array[
    'public.jl_admin_cancel_ludo_room(text,uuid,text)'::regprocedure,
    'public.jl_admin_cancel_all_ludo(text,text)'::regprocedure
  ]
  loop
    select pg_get_functiondef(v_sig) into v_def;
    if position(v_old in v_def)>0 then
      v_def:=replace(v_def,v_old,'perform public.jl_require_admin_elevated(p_token);');
      execute v_def;
    end if;
  end loop;
end
$$;

do $$
declare
  v_def text;
  v_start integer;
  v_end integer;
begin
  select pg_get_functiondef('public.jl_admin_delete_player(text,uuid,text)'::regprocedure)
  into v_def;

  v_start:=position('select code_hash into v_hash from public.admin_config' in v_def);
  v_end:=position('select name into v_name' in v_def);

  if v_start>0 and v_end>v_start then
    v_def:=substr(v_def,1,v_start-1)
      || 'if not public.jl_admin_verify_code_for_token(p_token,p_admin_pin) then' || E'\n'
      || '    raise exception ''PIN administrativo incorreto.'';' || E'\n'
      || '  end if;' || E'\n\n  '
      || substr(v_def,v_end);
    execute v_def;
  end if;
end
$$;

do $$
declare
  v_def text;
  v_start integer;
  v_end integer;
begin
  select pg_get_functiondef('public.jl_admin_reset_financial_counters(text,text)'::regprocedure)
  into v_def;

  v_start:=position('select code_hash into v_hash' in v_def);
  v_end:=position('insert into public.admin_metric_baselines' in v_def);

  if v_start>0 and v_end>v_start then
    v_def:=substr(v_def,1,v_start-1)
      || 'if not public.jl_admin_verify_code_for_token(p_token,p_admin_pin) then' || E'\n'
      || '    raise exception ''PIN administrativo incorreto.'';' || E'\n'
      || '  end if;' || E'\n\n  '
      || substr(v_def,v_end);
    execute v_def;
  end if;
end
$$;

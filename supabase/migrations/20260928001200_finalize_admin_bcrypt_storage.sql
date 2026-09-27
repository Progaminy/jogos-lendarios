-- Ponto 7 — finaliza a migração do código administrativo para armazenamento lento.
-- Como o código em claro não existe no banco, o SHA-256 legado é primeiro protegido
-- por bcrypt e, no próximo login/reautenticação válida, passa automaticamente
-- para bcrypt direto do código digitado.

alter table public.admin_accounts
  add column if not exists code_scheme text not null default 'bcrypt'
  check (code_scheme in ('bcrypt','bcrypt_sha256'));

update public.admin_accounts
set code_hash=extensions.crypt(legacy_sha256_hash,extensions.gen_salt('bf',12)),
    legacy_sha256_hash=null,
    code_scheme='bcrypt_sha256',
    updated_at=now()
where legacy_sha256_hash is not null;

update public.admin_config c
set code_hash=a.code_hash,
    updated_at=now()
from public.admin_accounts a
where a.is_primary
  and a.code_hash is not null;

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

  if a.id is null or not a.active or a.code_hash is null then
    return false;
  end if;

  if a.code_scheme='bcrypt'
     and extensions.crypt(coalesce(p_code,''),a.code_hash)=a.code_hash then
    return true;
  end if;

  if a.code_scheme='bcrypt_sha256' then
    v_sha:=encode(extensions.digest(coalesce(p_code,''),'sha256'),'hex');
    if extensions.crypt(v_sha,a.code_hash)=a.code_hash then
      v_new_hash:=extensions.crypt(coalesce(p_code,''),extensions.gen_salt('bf',12));

      update public.admin_accounts
      set code_hash=v_new_hash,
          code_scheme='bcrypt',
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
  v_sha text:=encode(extensions.digest(coalesce(p_code,''),'sha256'),'hex');
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

  for a in
    select id,code_hash,code_scheme
    from public.admin_accounts
    where active
  loop
    if (a.code_scheme='bcrypt' and extensions.crypt(p_code,a.code_hash)=a.code_hash)
       or (a.code_scheme='bcrypt_sha256' and extensions.crypt(v_sha,a.code_hash)=a.code_hash) then
      raise exception 'Este código já pertence a outro administrador.';
    end if;
  end loop;

  insert into public.admin_accounts(display_name,role,code_hash,code_scheme,active)
  values(v_name,v_role,extensions.crypt(p_code,extensions.gen_salt('bf',12)),'bcrypt',true)
  returning id into v_id;

  return jsonb_build_object('ok',true,'id',v_id,'name',v_name,'role',v_role);
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
  v_sha text:=encode(extensions.digest(coalesce(p_new_code,''),'sha256'),'hex');
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

  for a in
    select id,code_hash,code_scheme
    from public.admin_accounts
    where active and id<>v_me
  loop
    if (a.code_scheme='bcrypt' and extensions.crypt(p_new_code,a.code_hash)=a.code_hash)
       or (a.code_scheme='bcrypt_sha256' and extensions.crypt(v_sha,a.code_hash)=a.code_hash) then
      raise exception 'Este código já pertence a outro administrador.';
    end if;
  end loop;

  v_hash:=extensions.crypt(p_new_code,extensions.gen_salt('bf',12));

  update public.admin_accounts
  set code_hash=v_hash,
      legacy_sha256_hash=null,
      code_scheme='bcrypt',
      updated_at=now()
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

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(3);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_admin_verify_account_code(uuid,text)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%update public.admin_config set code_hash=v_new_hash, updated_at=now() where id=( select c.id from public.admin_config c order by c.id limit 1 )%',
  'Admin: migração automática do código principal atualiza admin_config com WHERE'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_admin_change_own_code(text,text,text)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%update public.admin_config set code_hash=v_hash, updated_at=now() where id=( select c.id from public.admin_config c order by c.id limit 1 )%',
  'Admin: alteração do próprio código atualiza admin_config com WHERE'
);

select ok(
  lower(pg_get_functiondef('public.jl_admin_login(text)'::regprocedure))
    like '%jl_admin_verify_account_code(v_candidate,p_code)%',
  'Admin: login continua a validar e migrar o código pela rotina protegida'
);

select * from finish();
rollback;

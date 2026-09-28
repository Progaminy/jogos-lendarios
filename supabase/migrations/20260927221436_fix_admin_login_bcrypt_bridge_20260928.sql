-- Ponto 7 — compatibilidade imediata após remover o SHA-256 simples.
-- O administrador principal foi convertido para bcrypt(SHA-256(código)) sem
-- conhecer o código em claro. jl_admin_login deve reconhecer esse formato
-- transitório e, no primeiro acesso válido, jl_admin_verify_account_code
-- converte automaticamente para bcrypt direto do código.

do $$
declare
  v_def text;
  v_old text := 'if extensions.crypt(coalesce(p_code,''''),v_admin.code_hash)=v_admin.code_hash then';
  v_new text := 'if (v_admin.code_scheme=''bcrypt'' and extensions.crypt(coalesce(p_code,''''),v_admin.code_hash)=v_admin.code_hash)' ||
                ' or (v_admin.code_scheme=''bcrypt_sha256'' and extensions.crypt(v_sha,v_admin.code_hash)=v_admin.code_hash) then';
begin
  select pg_get_functiondef('public.jl_admin_login(text)'::regprocedure)
  into v_def;

  if position(v_old in v_def)=0 then
    raise exception 'Trecho esperado de jl_admin_login não encontrado.';
  end if;

  v_def:=replace(v_def,v_old,v_new);
  execute v_def;
end
$$;

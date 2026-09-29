begin;

do $$
declare
  v_def text;
  v_blocked boolean:=false;
begin
  if to_regprocedure(
    'public.jl_aviator_admin_bank_ledger(text,integer)'
  ) is null then
    raise exception 'RPC de ledger admin ausente';
  end if;

  select pg_get_functiondef(
    'public.jl_aviator_admin_bank_ledger(text,integer)'::regprocedure
  )
  into v_def;

  if position('jl_require_admin' in v_def)=0 then
    raise exception 'RPC de ledger deve exigir sessao admin';
  end if;

  if position('least(50' in replace(lower(v_def),' ',''))=0 then
    raise exception 'RPC de ledger deve limitar resultados';
  end if;

  begin
    perform public.jl_aviator_admin_bank_ledger(
      'token-admin-invalido',
      30
    );
  exception
    when others then
      v_blocked:=true;
  end;

  if not v_blocked then
    raise exception 'token admin invalido nao foi bloqueado';
  end if;

  if has_table_privilege(
    'anon',
    'public.jl_aviator_bank_ledger',
    'SELECT'
  ) then
    raise exception 'anon nao pode ler ledger diretamente';
  end if;
end
$$;

rollback;

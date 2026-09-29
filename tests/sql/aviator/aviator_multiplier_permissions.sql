begin;

do $$
begin
  if has_function_privilege('anon','public.jl_aviator_multiplier(timestamptz,timestamptz)','EXECUTE') then
    raise exception 'anon nao pode executar jl_aviator_multiplier';
  end if;

  if has_function_privilege('authenticated','public.jl_aviator_multiplier(timestamptz,timestamptz)','EXECUTE') then
    raise exception 'authenticated nao pode executar jl_aviator_multiplier';
  end if;

  if not has_function_privilege('service_role','public.jl_aviator_multiplier(timestamptz,timestamptz)','EXECUTE') then
    raise exception 'service_role precisa executar jl_aviator_multiplier';
  end if;
end
$$;

rollback;

-- Aviator: helper de multiplicador e interno; cliente recebe apenas estado publico.
revoke execute on function public.jl_aviator_multiplier(timestamptz,timestamptz) from public;
grant execute on function public.jl_aviator_multiplier(timestamptz,timestamptz) to service_role;
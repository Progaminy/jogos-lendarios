-- O agregador de reconexao nao precisa executar com privilegios do owner.
-- As funcoes filhas fazem a validacao/autorizacao necessaria.
alter function public.jl_aviator_reconnect(text) security invoker;

revoke all on function public.jl_aviator_reconnect(text) from public;
grant execute on function public.jl_aviator_reconnect(text)
to anon,authenticated,service_role;

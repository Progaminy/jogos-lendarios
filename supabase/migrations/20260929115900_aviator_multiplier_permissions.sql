-- Aviator: fechar explicitamente o helper de multiplicador para browser roles.
-- Revogar de PUBLIC nao remove grants explicitos ja dados a anon/authenticated.

revoke execute on function public.jl_aviator_multiplier(timestamptz,timestamptz)
  from public,anon,authenticated;

grant execute on function public.jl_aviator_multiplier(timestamptz,timestamptz)
  to service_role;

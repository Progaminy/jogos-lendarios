-- Ponto 2 da auditoria de segurança:
-- jl_admin_game_snapshot é uma função administrativa SECURITY DEFINER e não
-- recebe token administrativo. Ela não deve ser executável pelo cliente público.
--
-- Mantemos a função intacta e alteramos somente a superfície de acesso.

revoke execute on function public.jl_admin_game_snapshot(text)
from public, anon, authenticated;

grant execute on function public.jl_admin_game_snapshot(text)
to service_role;

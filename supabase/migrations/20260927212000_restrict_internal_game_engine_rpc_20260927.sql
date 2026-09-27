-- Ponto 3 da auditoria de segurança:
-- impedir que o navegador/jogador invoque diretamente funções internas do motor.
-- A lógica das funções não é alterada; somente as permissões de EXECUTE.

revoke execute on function public.jl_finalize_game_due_rounds(text)
from public, anon, authenticated;
grant execute on function public.jl_finalize_game_due_rounds(text)
to service_role;

revoke execute on function public.jl_open_next_game_round(text)
from public, anon, authenticated;
grant execute on function public.jl_open_next_game_round(text)
to service_role;

revoke execute on function public.jl_open_next_scheduled_round()
from public, anon, authenticated;
grant execute on function public.jl_open_next_scheduled_round()
to service_role;

revoke execute on function public.jl_process_game(text)
from public, anon, authenticated;
grant execute on function public.jl_process_game(text)
to service_role;

revoke execute on function public.jl_process_game_engine()
from public, anon, authenticated;
grant execute on function public.jl_process_game_engine()
to service_role;

revoke execute on function public.jl_secure_number(uuid)
from public, anon, authenticated;
grant execute on function public.jl_secure_number(uuid)
to service_role;

revoke execute on function public.jl_secure_pair(uuid)
from public, anon, authenticated;
grant execute on function public.jl_secure_pair(uuid)
to service_role;

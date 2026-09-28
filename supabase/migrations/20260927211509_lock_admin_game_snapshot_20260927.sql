revoke execute on function public.jl_admin_game_snapshot(text)
from public, anon, authenticated;

grant execute on function public.jl_admin_game_snapshot(text)
to service_role;
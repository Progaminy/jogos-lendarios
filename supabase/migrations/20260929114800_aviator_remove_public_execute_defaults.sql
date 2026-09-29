-- Aviator: remover EXECUTE implicito de PUBLIC das APIs novas.
revoke execute on function public.jl_aviator_place_bet(text,numeric,text) from public;
revoke execute on function public.jl_aviator_player_state(text) from public;
revoke execute on function public.jl_aviator_admin_adjust_bank(text,numeric,text,text) from public;
grant execute on function public.jl_aviator_place_bet(text,numeric,text) to anon,authenticated;
grant execute on function public.jl_aviator_player_state(text) to anon,authenticated;
grant execute on function public.jl_aviator_admin_adjust_bank(text,numeric,text,text) to anon,authenticated;
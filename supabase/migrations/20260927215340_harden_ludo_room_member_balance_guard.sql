drop trigger if exists trg_jl_guard_ludo_room_member_funds
on public.ludo_room_players;

create trigger trg_jl_guard_ludo_room_member_funds
before insert or update of room_id, player_id, status
on public.ludo_room_players
for each row
execute function public.jl_guard_ludo_room_member_funds();
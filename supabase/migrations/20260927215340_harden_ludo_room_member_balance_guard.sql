-- Ponto 6: endurecer o bloqueio de entrada/ocupação de salas de Ludo sem saldo suficiente.
-- A função de guarda já valida o saldo contra o valor atual da sala.
-- Esta migration amplia o trigger para também cobrir futuras reutilizações/reativações
-- de registos de jogador em sala, sem alterar regras, valores, turnos ou interface.

drop trigger if exists trg_jl_guard_ludo_room_member_funds
on public.ludo_room_players;

create trigger trg_jl_guard_ludo_room_member_funds
before insert or update of room_id, player_id, status
on public.ludo_room_players
for each row
execute function public.jl_guard_ludo_room_member_funds();

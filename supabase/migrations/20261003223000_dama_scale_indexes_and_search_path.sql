-- Dama Lendária — índices de escala e hardening leve.
-- Mantém tabelas fechadas por RLS/RPC e evita varreduras desnecessárias com muitas partidas.

create index if not exists dama_room_players_player_id_idx
  on public.dama_room_players(player_id, room_id);

create index if not exists dama_pieces_player_id_idx
  on public.dama_pieces(player_id)
  where alive;

create index if not exists dama_events_player_id_idx
  on public.dama_events(player_id)
  where player_id is not null;

create index if not exists dama_payouts_player_id_idx
  on public.dama_payouts(player_id);

create index if not exists dama_rooms_host_id_idx
  on public.dama_rooms(host_id, created_at desc);

create index if not exists dama_rooms_guest_id_idx
  on public.dama_rooms(guest_id, created_at desc)
  where guest_id is not null;

create index if not exists dama_rooms_current_player_id_idx
  on public.dama_rooms(current_player_id)
  where current_player_id is not null and status='playing';

create index if not exists dama_rooms_winner_player_id_idx
  on public.dama_rooms(winner_player_id)
  where winner_player_id is not null;

create index if not exists dama_rooms_draw_offer_by_idx
  on public.dama_rooms(draw_offer_by)
  where draw_offer_by is not null;

create index if not exists dama_signals_from_player_id_idx
  on public.dama_signals(from_player_id);

create index if not exists dama_signals_to_player_id_idx
  on public.dama_signals(to_player_id, room_id, id);

create index if not exists board_invitations_target_id_idx
  on public.board_invitations(target_id, status, created_at desc);

alter function public.jl_dama_square_name(integer,integer)
  set search_path = public;

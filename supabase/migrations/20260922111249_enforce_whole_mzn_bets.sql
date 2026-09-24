alter table public.game_settings
  drop constraint if exists game_settings_whole_mzn_check;
alter table public.game_settings
  add constraint game_settings_whole_mzn_check
  check (
    min_bet >= 10
    and min_bet = trunc(min_bet)
    and max_bet >= min_bet
    and max_bet = trunc(max_bet)
  );

alter table public.bets
  drop constraint if exists bets_amount_whole_mzn_check;
alter table public.bets
  add constraint bets_amount_whole_mzn_check
  check (amount = trunc(amount));

alter table public.pair_bets
  drop constraint if exists pair_bets_amount_whole_mzn_check;
alter table public.pair_bets
  add constraint pair_bets_amount_whole_mzn_check
  check (amount = trunc(amount));

alter table public.ludo_rooms
  drop constraint if exists ludo_rooms_bet_whole_mzn_check;
alter table public.ludo_rooms
  add constraint ludo_rooms_bet_whole_mzn_check
  check (bet_amount = trunc(bet_amount));

alter table public.ludo_waiting_queue
  drop constraint if exists ludo_waiting_queue_bet_whole_mzn_check;
alter table public.ludo_waiting_queue
  add constraint ludo_waiting_queue_bet_whole_mzn_check
  check (bet_amount = trunc(bet_amount));

alter table public.ludo_room_players
  drop constraint if exists ludo_room_players_stake_whole_mzn_check;
alter table public.ludo_room_players
  add constraint ludo_room_players_stake_whole_mzn_check
  check (stake_amount is null or stake_amount = trunc(stake_amount));

alter table public.ludo_rooms
  drop constraint if exists ludo_rooms_reentry_whole_mzn_check;
alter table public.ludo_rooms
  add constraint ludo_rooms_reentry_whole_mzn_check
  check (
    not (rules ? 'reentry_amount')
    or (
      (rules->>'reentry_amount')::numeric >= 10
      and (rules->>'reentry_amount')::numeric = trunc((rules->>'reentry_amount')::numeric)
    )
  );

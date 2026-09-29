alter table public.game_settings
  drop constraint if exists game_settings_whole_mzn_check;

alter table public.game_settings
  add constraint game_settings_whole_mzn_check
  check (
    min_bet >= 1
    and min_bet = trunc(min_bet)
    and max_bet >= min_bet
    and max_bet = trunc(max_bet)
  );

update public.game_settings
set min_bet = 1
where game_type in ('number','pair');

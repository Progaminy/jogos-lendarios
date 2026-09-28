create index if not exists bonus_usages_grant_id_idx
  on public.bonus_usages (grant_id);

create index if not exists bonus_usages_player_id_idx
  on public.bonus_usages (player_id);

create index if not exists deposit_wager_usages_requirement_id_idx
  on public.deposit_wager_usages (requirement_id);

create index if not exists draw_schedule_round_id_idx
  on public.draw_schedule (round_id);

create index if not exists game_rounds_schedule_id_idx
  on public.game_rounds (schedule_id);
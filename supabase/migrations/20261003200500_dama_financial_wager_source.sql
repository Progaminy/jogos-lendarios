alter table public.deposit_wager_usages
  drop constraint if exists deposit_wager_usages_source_type_check;

alter table public.deposit_wager_usages
  add constraint deposit_wager_usages_source_type_check check (
    source_type = any(array[
      'number_bet','pair_bet','ludo_stake','ludo_reentry','aviator_bet','dama_stake'
    ]::text[])
  );
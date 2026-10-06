-- Allow zero stake for FREE Dama rooms while keeping integer non-negative amounts.
alter table public.dama_rooms drop constraint if exists dama_rooms_bet_check;
alter table public.dama_rooms
  add constraint dama_rooms_bet_check
  check (bet_amount >= 0 and bet_amount = trunc(bet_amount));

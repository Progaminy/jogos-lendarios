-- Allow zero stake for FREE Ludo rooms while keeping negative stakes invalid.
alter table public.ludo_rooms drop constraint if exists ludo_rooms_bet_amount_check;
alter table public.ludo_rooms
  add constraint ludo_rooms_bet_amount_check check (bet_amount >= 0);

alter table public.ludo_waiting_queue drop constraint if exists ludo_waiting_queue_bet_amount_check;
alter table public.ludo_waiting_queue
  add constraint ludo_waiting_queue_bet_amount_check check (bet_amount >= 0);

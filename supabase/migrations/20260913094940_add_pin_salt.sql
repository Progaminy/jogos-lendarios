alter table public.players add column if not exists pin_salt text;
alter table public.players drop constraint if exists players_pin_salt_length;
alter table public.players add constraint players_pin_salt_length check (pin_salt is null or char_length(pin_salt) = 32);

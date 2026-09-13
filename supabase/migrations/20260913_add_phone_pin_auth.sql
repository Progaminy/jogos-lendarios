alter table public.players add column if not exists phone text;
alter table public.players add column if not exists pin_hash text;
create unique index if not exists players_phone_unique on public.players (phone) where phone is not null;
alter table public.players drop constraint if exists players_phone_format;
alter table public.players add constraint players_phone_format check (phone is null or char_length(phone) between 8 and 20);
alter table public.players drop constraint if exists players_pin_hash_length;
alter table public.players add constraint players_pin_hash_length check (pin_hash is null or char_length(pin_hash) = 64);

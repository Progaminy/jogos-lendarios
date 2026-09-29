-- Aviator: chave idempotente para impedir aposta duplicada em retry de rede.
alter table public.jl_aviator_bets add column if not exists request_key text;
create unique index if not exists jl_aviator_bets_player_request_key_uidx
on public.jl_aviator_bets(player_id,request_key) where request_key is not null;

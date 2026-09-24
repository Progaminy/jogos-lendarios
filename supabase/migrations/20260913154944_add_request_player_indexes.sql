create index if not exists deposit_requests_player_idx on public.deposit_requests(player_id, created_at desc);
create index if not exists withdrawal_requests_player_idx on public.withdrawal_requests(player_id, created_at desc);

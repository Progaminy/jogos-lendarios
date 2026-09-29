-- Aviator: chave de manutencao controlada pelo admin.
create table if not exists public.jl_aviator_settings(id boolean primary key default true check(id),enabled boolean not null default true,maintenance_message text not null default 'Aviator em manutencao. Volte em breve.',updated_at timestamptz not null default now());
insert into public.jl_aviator_settings(id) values(true) on conflict(id) do nothing;
alter table public.jl_aviator_settings enable row level security;
revoke all on public.jl_aviator_settings from public,anon,authenticated;
-- As funcoes instaladas nesta migration impedem novas apostas/rodadas quando enabled=false.
-- Rodadas LOCKED/FLYING existentes continuam ate liquidacao para preservar dinheiro dos jogadores.

-- Aviator: manter a seed visual fora do estado publico durante o voo.
create table if not exists public.jl_aviator_round_secrets (
  round_id bigint primary key references public.jl_aviator_rounds(id) on delete cascade,
  seed text not null,
  unit_value numeric(18,12) not null check (unit_value >= 0 and unit_value <= 1),
  created_at timestamptz not null default now()
);

alter table public.jl_aviator_round_secrets enable row level security;
revoke all on public.jl_aviator_round_secrets from anon, authenticated;

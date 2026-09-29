-- Aviator Lendario: motor financeiro base (fase 1)
-- Regra acordada: todas as apostas validas entram; a reserva de risco da casa e 50% da banca.
-- O teto e congelado quando a rodada fecha. Cash-outs nao recalculam o teto.

create table if not exists public.jl_aviator_bank (
  id boolean primary key default true check (id),
  balance numeric(18,2) not null default 0 check (balance >= 0),
  exposure_ratio numeric(8,6) not null default 0.5 check (exposure_ratio > 0 and exposure_ratio <= 1),
  updated_at timestamptz not null default now()
);

insert into public.jl_aviator_bank(id,balance,exposure_ratio)
values (true,0,0.5) on conflict (id) do nothing;

create table if not exists public.jl_aviator_rounds (
  id bigint generated always as identity primary key,
  status text not null default 'OPEN' check (status in ('OPEN','LOCKED','FLYING','CRASHED','SETTLED','CANCELLED')),
  opened_at timestamptz not null default now(),
  locked_at timestamptz,
  started_at timestamptz,
  crashed_at timestamptz,
  settled_at timestamptz,
  bank_balance_snapshot numeric(18,2),
  risk_reserve numeric(18,2),
  total_staked numeric(18,2) not null default 0,
  financial_ceiling numeric(18,6),
  crash_multiplier numeric(18,6),
  zero_exposure_at_multiplier numeric(18,6),
  visual_extension boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.jl_aviator_bets (
  id bigint generated always as identity primary key,
  round_id bigint not null references public.jl_aviator_rounds(id),
  player_id uuid not null references public.players(id),
  stake numeric(18,2) not null check (stake > 0),
  status text not null default 'ACTIVE' check (status in ('ACTIVE','CASHED_OUT','LOST','REFUNDED')),
  cashout_multiplier numeric(18,6),
  payout numeric(18,2),
  created_at timestamptz not null default now(),
  cashed_out_at timestamptz
);
create index if not exists jl_aviator_bets_round_status_idx on public.jl_aviator_bets(round_id,status);
create index if not exists jl_aviator_bets_player_idx on public.jl_aviator_bets(player_id,created_at desc);

create or replace function public.jl_aviator_financial_ceiling(
  p_bank_balance numeric,
  p_total_staked numeric,
  p_exposure_ratio numeric default 0.5
) returns numeric
language plpgsql immutable strict
as $$
declare
  v_reserve numeric;
begin
  if p_bank_balance < 0 or p_total_staked < 0 then
    raise exception 'Valores negativos nao sao permitidos';
  end if;
  if p_exposure_ratio <= 0 or p_exposure_ratio > 1 then
    raise exception 'Exposure ratio invalido';
  end if;
  if p_total_staked = 0 then return null; end if;
  v_reserve := p_bank_balance * p_exposure_ratio;
  return 1 + (v_reserve / p_total_staked);
end;
$$;

create or replace function public.jl_aviator_lock_round(p_round_id bigint)
returns public.jl_aviator_rounds
language plpgsql security definer
set search_path = public
as $$
declare
  v_round public.jl_aviator_rounds;
  v_bank public.jl_aviator_bank;
  v_total numeric;
begin
  select * into v_round from public.jl_aviator_rounds where id=p_round_id for update;
  if not found or v_round.status <> 'OPEN' then raise exception 'Rodada nao esta OPEN'; end if;
  select * into v_bank from public.jl_aviator_bank where id=true for update;
  select coalesce(sum(stake),0) into v_total from public.jl_aviator_bets where round_id=p_round_id and status='ACTIVE';

  update public.jl_aviator_rounds
  set status='LOCKED', locked_at=now(),
      bank_balance_snapshot=v_bank.balance,
      risk_reserve=round(v_bank.balance*v_bank.exposure_ratio,2),
      total_staked=v_total,
      financial_ceiling=public.jl_aviator_financial_ceiling(v_bank.balance,v_total,v_bank.exposure_ratio)
  where id=p_round_id returning * into v_round;
  return v_round;
end;
$$;

alter table public.jl_aviator_bank enable row level security;
alter table public.jl_aviator_rounds enable row level security;
alter table public.jl_aviator_bets enable row level security;

revoke all on public.jl_aviator_bank from anon, authenticated;
revoke insert, update, delete on public.jl_aviator_rounds from anon, authenticated;
revoke insert, update, delete on public.jl_aviator_bets from anon, authenticated;
revoke execute on function public.jl_aviator_lock_round(bigint) from public, anon, authenticated;
grant execute on function public.jl_aviator_lock_round(bigint) to service_role;
revoke execute on function public.jl_aviator_financial_ceiling(numeric,numeric,numeric) from public, anon, authenticated;
grant execute on function public.jl_aviator_financial_ceiling(numeric,numeric,numeric) to service_role;

-- Aviator: defesa em profundidade para aposta minima de 0,50 MZN.
-- A RPC ja valida p_amount >= 0.50. Esta constraint impede que qualquer
-- caminho interno, service_role ou RPC futura grave stake abaixo do minimo.

alter table public.jl_aviator_bets
  drop constraint if exists jl_aviator_bets_stake_check;

alter table public.jl_aviator_bets
  add constraint jl_aviator_bets_stake_check
  check (stake >= 0.50);

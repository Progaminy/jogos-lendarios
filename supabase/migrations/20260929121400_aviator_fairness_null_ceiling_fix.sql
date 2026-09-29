-- Provably fair v2: o teto financeiro e NULL quando nao ha apostas.
-- O payload precisa representar esse estado como a string literal NULL.
create or replace function public.jl_aviator_fairness_lock_payload(
  p_round_id bigint,
  p_seed_commit text,
  p_total_staked numeric,
  p_financial_ceiling numeric,
  p_visual_target numeric,
  p_locked_effective_target numeric
)
returns text
language sql
immutable
set search_path=pg_catalog,public
as $$
  select concat_ws(
    '|',
    'JL-AVIATOR-PF-v2',
    p_round_id::text,
    p_seed_commit,
    to_char(p_total_staked,'FM999999999999990.00'),
    coalesce(to_char(p_financial_ceiling,'FM999999999999990.000000'),'NULL'),
    to_char(p_visual_target,'FM999999999999990.000000'),
    to_char(p_locked_effective_target,'FM999999999999990.000000')
  );
$$;

revoke all on function public.jl_aviator_fairness_lock_payload(bigint,text,numeric,numeric,numeric,numeric)
from public,anon,authenticated;
grant execute on function public.jl_aviator_fairness_lock_payload(bigint,text,numeric,numeric,numeric,numeric)
to service_role;

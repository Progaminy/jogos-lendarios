create or replace function public.jl_player_bet_summary(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := public.jl_player_id(p_token);
  result jsonb;
begin
  with all_bets as (
    select amount, won, payout from public.bets where player_id=me
    union all
    select amount, won, payout from public.pair_bets where player_id=me
  )
  select jsonb_build_object(
    'total_count', count(*),
    'total_amount', coalesce(sum(amount),0),
    'pending_count', count(*) filter (where won is null),
    'pending_amount', coalesce(sum(amount) filter (where won is null),0),
    'loss_count', count(*) filter (where won is false),
    'loss_amount', coalesce(sum(amount) filter (where won is false),0),
    'win_count', count(*) filter (where won is true),
    'win_stake_amount', coalesce(sum(amount) filter (where won is true),0),
    'win_payout_amount', coalesce(sum(payout) filter (where won is true),0),
    'net_result', coalesce(sum(case when won is true then coalesce(payout,0)-amount when won is false then -amount else 0 end),0)
  ) into result
  from all_bets;
  return result;
end;
$$;

create or replace function public.jl_admin_bet_summary(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result jsonb;
begin
  perform public.jl_require_admin(p_token);
  with all_bets as (
    select amount, won, payout, 'number'::text as game_type from public.bets
    union all
    select amount, won, payout, 'pair'::text as game_type from public.pair_bets
  )
  select jsonb_build_object(
    'total_count', count(*),
    'total_amount', coalesce(sum(amount),0),
    'pending_count', count(*) filter (where won is null),
    'pending_amount', coalesce(sum(amount) filter (where won is null),0),
    'loss_count', count(*) filter (where won is false),
    'loss_amount', coalesce(sum(amount) filter (where won is false),0),
    'win_count', count(*) filter (where won is true),
    'win_stake_amount', coalesce(sum(amount) filter (where won is true),0),
    'win_payout_amount', coalesce(sum(payout) filter (where won is true),0),
    'house_net_settled', coalesce(sum(case when won is true then amount-coalesce(payout,0) when won is false then amount else 0 end),0),
    'number_count', count(*) filter (where game_type='number'),
    'pair_count', count(*) filter (where game_type='pair')
  ) into result
  from all_bets;
  return result;
end;
$$;

revoke execute on function public.jl_player_bet_summary(text) from public;
revoke execute on function public.jl_admin_bet_summary(text) from public;
grant execute on function public.jl_player_bet_summary(text) to anon, authenticated;
grant execute on function public.jl_admin_bet_summary(text) to anon, authenticated;

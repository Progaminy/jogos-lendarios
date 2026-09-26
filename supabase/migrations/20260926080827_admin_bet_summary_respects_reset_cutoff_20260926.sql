create or replace function public.jl_admin_bet_summary(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  result jsonb;
  v_reset_at timestamptz;
begin
  perform public.jl_require_admin(p_token);

  select reset_at
    into v_reset_at
  from public.admin_metric_baselines
  where id = 1;

  if v_reset_at is null then
    v_reset_at := '-infinity'::timestamptz;
  end if;

  with all_bets as (
    select amount, won, payout, 'number'::text as game_type
    from public.bets
    where created_at > v_reset_at
    union all
    select amount, won, payout, 'pair'::text as game_type
    from public.pair_bets
    where created_at > v_reset_at
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
    'house_net_settled', coalesce(sum(
      case
        when won is true then amount-coalesce(payout,0)
        when won is false then amount
        else 0
      end
    ),0),
    'number_count', count(*) filter (where game_type='number'),
    'pair_count', count(*) filter (where game_type='pair'),
    'since', v_reset_at
  )
  into result
  from all_bets;

  return result;
end;
$$;

revoke execute on function public.jl_admin_bet_summary(text) from public, authenticated;
grant execute on function public.jl_admin_bet_summary(text) to anon, service_role;

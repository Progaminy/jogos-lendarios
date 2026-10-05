create or replace function public.jl_free_catalog()
returns jsonb
language sql
stable
security definer
set search_path='pg_catalog','public'
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'game_key',g.game_key,
    'label',g.label,
    'free_enabled',g.free_enabled,
    'bet_enabled',g.bet_enabled,
    'trial_limit',g.trial_limit
  ) order by g.sort_order,g.game_key),'[]'::jsonb)
  from public.free_game_catalog g;
$$;

grant execute on function public.jl_free_catalog() to anon,authenticated;

-- Aviator: histórico público leve, separado do estado de voo.
-- Evita anexar uma lista de rodadas ao RPC consultado em alta frequência.

create or replace function public.jl_aviator_recent_results(p_limit integer default 12)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_limit integer:=least(20,greatest(1,coalesce(p_limit,12)));
  v_results jsonb;
begin
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',q.id,
        'crash_multiplier',q.crash_multiplier,
        'ended_at',q.ended_at
      )
      order by q.id desc
    ),
    '[]'::jsonb
  )
  into v_results
  from (
    select
      r.id,
      r.crash_multiplier,
      coalesce(r.settled_at,r.crashed_at) as ended_at
    from public.jl_aviator_rounds r
    where r.status in ('CRASHED','SETTLED')
      and r.crash_multiplier is not null
    order by r.id desc
    limit v_limit
  ) q;

  return v_results;
end
$$;

revoke all on function public.jl_aviator_recent_results(integer) from public;
grant execute on function public.jl_aviator_recent_results(integer) to anon,authenticated;

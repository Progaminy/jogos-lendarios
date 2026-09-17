alter table public.ludo_player_codes alter column house_number restart with 1;
insert into public.ludo_player_codes(player_id)
select p.id from public.players p
where not exists(select 1 from public.ludo_player_codes c where c.player_id=p.id)
order by p.created_at,p.id;

create or replace function public.jl_ludo_find_players(p_token text, p_query text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare me uuid := public.jl_player_id(p_token); q text := trim(coalesce(p_query,''));
begin
  perform public.jl_ludo_ensure_code(me);
  insert into public.ludo_player_codes(player_id)
  select p.id from public.players p
  where not p.blocked and not exists(select 1 from public.ludo_player_codes c where c.player_id=p.id)
  order by p.created_at,p.id
  on conflict(player_id) do nothing;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'player_id',x.id,'name',x.name,'code',public.jl_ludo_display_code(x.id),'house_number',x.house_number,
      'waiting',exists(select 1 from public.ludo_waiting_queue w where w.player_id=x.id and w.expires_at>now())
    ) order by x.name,x.house_number)
    from (
      select p.id,p.name,c.house_number
      from public.players p
      join public.ludo_player_codes c on c.player_id=p.id
      where p.id<>me and not p.blocked
        and (q='' or p.name ilike '%'||q||'%' or public.jl_ludo_display_code(p.id) ilike '%'||q||'%')
      order by p.name,c.house_number
      limit 30
    ) x
  ),'[]'::jsonb);
end;
$$;
revoke execute on function public.jl_ludo_find_players(text,text) from public;
grant execute on function public.jl_ludo_find_players(text,text) to anon, authenticated;

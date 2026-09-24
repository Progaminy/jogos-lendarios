create or replace function public.jl_ludo_sync_room(p_token text,p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  joined_count int;
  accepted_count int;
  paid_count int;
  stake_secs int;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.id is null or not public.jl_ludo_is_member(p_room,me) then raise exception 'Sala inválida.'; end if;
  if r.status in ('finished','cancelled','playing') then return public.jl_ludo_room_state(p_token,p_room); end if;

  select
    count(*) filter (where status<>'left'),
    count(*) filter (where status<>'left' and accepted_rules_version=r.rules_version),
    count(*) filter (where status<>'left' and stake_paid)
  into joined_count,accepted_count,paid_count
  from public.ludo_room_players
  where room_id=p_room;

  if joined_count=r.player_count and r.status='waiting' then
    update public.ludo_rooms
    set status='negotiating',action_deadline=now()+make_interval(secs=>coalesce((rules->>'rules_response_seconds')::int,60)),updated_at=now()
    where id=p_room;
    r.status:='negotiating';
  end if;

  if joined_count=r.player_count and accepted_count=joined_count and r.status='negotiating' then
    stake_secs := coalesce((r.rules->>'stake_seconds')::int,60);
    update public.ludo_rooms
    set status='funding',action_deadline=now()+make_interval(secs=>stake_secs),updated_at=now()
    where id=p_room;
    perform public.jl_ludo_event(p_room,me,'room_ready_for_stakes',jsonb_build_object('players',joined_count));
    r.status:='funding';
  end if;

  if joined_count=r.player_count and accepted_count=joined_count and paid_count=joined_count and r.status='funding' then
    perform public.jl_ludo_start_game(p_room);
  end if;

  return public.jl_ludo_room_state(p_token,p_room);
end;
$$;

revoke execute on function public.jl_ludo_sync_room(text,uuid) from public;
grant execute on function public.jl_ludo_sync_room(text,uuid) to anon, authenticated;

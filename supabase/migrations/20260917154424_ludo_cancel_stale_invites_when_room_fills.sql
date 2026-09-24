create or replace function public.jl_ludo_join_room_internal(p_room uuid, p_player uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r public.ludo_rooms%rowtype;
  s int;
  col text;
  tm int;
  joined_now int;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.id is null or r.status not in ('waiting','negotiating') then raise exception 'Sala indisponível.'; end if;

  if exists(select 1 from public.ludo_room_players where room_id=p_room and player_id=p_player and status<>'left') then return; end if;

  if exists(
    select 1 from public.ludo_room_players rp
    join public.ludo_rooms rr on rr.id=rp.room_id
    where rp.player_id=p_player and rp.status<>'left'
      and rr.status in ('waiting','negotiating','funding','playing') and rr.id<>p_room
  ) then raise exception 'O jogador já participa de outra sala ativa.'; end if;

  if (select count(*) from public.ludo_room_players where room_id=p_room and status<>'left') >= r.player_count then raise exception 'Sala cheia.'; end if;

  select x into s
  from generate_series(1,r.player_count) x
  where not exists(select 1 from public.ludo_room_players where room_id=p_room and seat=x and status<>'left')
  order by x limit 1;

  col := case s
    when 1 then 'red'
    when 2 then case when r.player_count=2 then 'yellow' else 'green' end
    when 3 then 'yellow'
    else 'blue'
  end;
  if r.player_count=2 and s=2 then col:='yellow'; end if;
  tm := case when r.mode='partners' then case when s in (1,3) then 1 else 2 end else null end;

  insert into public.ludo_room_players(room_id,player_id,seat,color,team,status)
  values(p_room,p_player,s,col,tm,'active');
  perform public.jl_ludo_ensure_code(p_player);

  update public.ludo_rooms
  set status='negotiating',
      action_deadline=now()+make_interval(secs=>(rules->>'rules_response_seconds')::int),
      negotiation_grace_used=false,
      updated_at=now()
  where id=p_room;

  perform public.jl_ludo_event(p_room,p_player,'player_joined',jsonb_build_object('seat',s,'color',col,'team',tm));

  select count(*) into joined_now
  from public.ludo_room_players
  where room_id=p_room and status<>'left';

  if joined_now >= r.player_count then
    update public.ludo_invitations i
    set status='cancelled'
    where i.room_id=p_room
      and i.status in ('pending','accepted')
      and i.target_player_id<>p_player
      and not exists(
        select 1 from public.ludo_room_players rp
        where rp.room_id=p_room and rp.player_id=i.target_player_id and rp.status<>'left'
      );
  end if;
end;
$function$;

update public.ludo_invitations i
set status='cancelled'
from public.ludo_rooms r
where r.id=i.room_id
  and i.status='accepted'
  and r.status in ('waiting','negotiating','funding','playing')
  and not exists(
    select 1 from public.ludo_room_players rp
    where rp.room_id=i.room_id and rp.player_id=i.target_player_id and rp.status<>'left'
  )
  and (select count(*) from public.ludo_room_players rp2 where rp2.room_id=r.id and rp2.status<>'left')>=r.player_count;

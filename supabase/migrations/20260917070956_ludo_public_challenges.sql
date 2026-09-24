create or replace function public.jl_ludo_public_challenges(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := public.jl_player_id(p_token);
begin
  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'room_id', r.id,
        'code', r.code,
        'host_id', r.host_id,
        'host_name', p.name,
        'host_code', public.jl_ludo_display_code(r.host_id),
        'player_count', r.player_count,
        'joined_count', x.joined_count,
        'open_slots', greatest(0, r.player_count - x.joined_count),
        'mode', r.mode,
        'bet_amount', r.bet_amount,
        'status', r.status,
        'play_location', coalesce(r.rules->>'play_location','online'),
        'dice_count', coalesce((r.rules->>'dice_count')::int,1),
        'expires_at', r.action_deadline,
        'created_at', r.created_at
      ) order by r.created_at desc
    )
    from public.ludo_rooms r
    join public.players p on p.id = r.host_id
    cross join lateral (
      select count(*)::int as joined_count
      from public.ludo_room_players rp
      where rp.room_id = r.id and rp.status <> 'left'
    ) x
    where r.is_public
      and r.status in ('waiting','negotiating')
      and r.host_id <> me
      and x.joined_count < r.player_count
      and (r.action_deadline is null or r.action_deadline > now())
      and not exists (
        select 1 from public.ludo_room_players mine
        where mine.room_id = r.id and mine.player_id = me and mine.status <> 'left'
      )
  ), '[]'::jsonb);
end;
$$;

create or replace function public.jl_ludo_rebroadcast_challenge(p_token text,p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  secs int;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.id is null or r.host_id <> me then raise exception 'Apenas o anfitrião pode relançar o desafio.'; end if;
  if not r.is_public or r.status not in ('waiting','negotiating') then raise exception 'Esta sala não pode ser anunciada agora.'; end if;
  if (select count(*) from public.ludo_room_players where room_id=p_room and status<>'left') >= r.player_count then raise exception 'A sala já está completa.'; end if;
  secs := coalesce((r.rules->>'invite_seconds')::int,60);
  update public.ludo_rooms set action_deadline=now()+make_interval(secs=>secs),updated_at=now() where id=p_room;
  perform public.jl_ludo_event(p_room,me,'public_challenge_rebroadcast',jsonb_build_object('expires_in',secs));
  return public.jl_ludo_room_state(p_token,p_room);
end;
$$;

revoke execute on function public.jl_ludo_public_challenges(text) from public;
revoke execute on function public.jl_ludo_rebroadcast_challenge(text,uuid) from public;
grant execute on function public.jl_ludo_public_challenges(text) to anon, authenticated;
grant execute on function public.jl_ludo_rebroadcast_challenge(text,uuid) to anon, authenticated;

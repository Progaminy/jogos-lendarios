-- Ludo: escolher sempre uma cor livre ao entrar numa sala.
-- Corrige o caso em que um jogador já mudou manualmente para a cor padrao do
-- proximo assento, o que causava unique(room_id,color).

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
  preferred_col text;
  tm int;
  joined_now int;
  other_color text;
begin
  perform 1
  from public.players
  where id=p_player
  for update;

  select * into r
  from public.ludo_rooms
  where id=p_room
  for update;

  if r.id is null or r.status not in ('waiting','negotiating') then
    raise exception 'Sala indisponível.';
  end if;

  if exists(
    select 1
    from public.ludo_room_players
    where room_id=p_room
      and player_id=p_player
      and status<>'left'
  ) then
    return;
  end if;

  perform public.jl_require_cash_balance(p_player,r.bet_amount);

  if exists(
    select 1
    from public.ludo_room_players rp
    join public.ludo_rooms rr on rr.id=rp.room_id
    where rp.player_id=p_player
      and rp.status<>'left'
      and rr.status in ('waiting','negotiating','funding','playing')
      and rr.id<>p_room
  ) then
    raise exception 'O jogador já participa de outra sala ativa.';
  end if;

  if (
    select count(*)
    from public.ludo_room_players
    where room_id=p_room
      and status<>'left'
  )>=r.player_count then
    raise exception 'Sala cheia.';
  end if;

  delete from public.ludo_room_players
  where room_id=p_room
    and status='left';

  select x into s
  from generate_series(1,r.player_count) x
  where not exists(
    select 1
    from public.ludo_room_players
    where room_id=p_room
      and seat=x
      and status<>'left'
  )
  order by x
  limit 1;

  if s is null then
    raise exception 'Sala cheia.';
  end if;

  if r.player_count=2 then
    select rp.color into other_color
    from public.ludo_room_players rp
    where rp.room_id=p_room
      and rp.status<>'left'
    order by rp.seat
    limit 1;

    col:=case other_color
      when 'red' then 'yellow'
      when 'yellow' then 'red'
      when 'green' then 'blue'
      when 'blue' then 'green'
      else case when s=1 then 'red' else 'yellow' end
    end;
  else
    preferred_col:=case s
      when 1 then 'red'
      when 2 then 'green'
      when 3 then 'yellow'
      else 'blue'
    end;

    select c into col
    from unnest(
      case preferred_col
        when 'red' then array['red','green','yellow','blue']::text[]
        when 'green' then array['green','red','yellow','blue']::text[]
        when 'yellow' then array['yellow','red','green','blue']::text[]
        else array['blue','red','green','yellow']::text[]
      end
    ) as c
    where not exists(
      select 1
      from public.ludo_room_players rp
      where rp.room_id=p_room
        and rp.status<>'left'
        and rp.color=c
    )
    limit 1;

    if col is null then
      raise exception 'Não há cor disponível nesta sala.';
    end if;
  end if;

  tm:=case
    when r.mode='partners' then case when s in (1,3) then 1 else 2 end
    else null
  end;

  insert into public.ludo_room_players(
    room_id,player_id,seat,color,team,status
  ) values(
    p_room,p_player,s,col,tm,'active'
  );

  perform public.jl_ludo_ensure_code(p_player);

  update public.ludo_rooms
  set status='negotiating',
      action_deadline=null,
      negotiation_grace_used=false,
      updated_at=now()
  where id=p_room;

  perform public.jl_ludo_event(
    p_room,p_player,'player_joined',
    jsonb_build_object(
      'seat',s,
      'color',col,
      'team',tm,
      'two_player_opposite',r.player_count=2
    )
  );

  select count(*) into joined_now
  from public.ludo_room_players
  where room_id=p_room
    and status<>'left';

  if joined_now>=r.player_count then
    update public.ludo_invitations i
    set status='cancelled'
    where i.room_id=p_room
      and i.status in ('pending','accepted')
      and i.target_player_id<>p_player
      and not exists(
        select 1
        from public.ludo_room_players rp
        where rp.room_id=p_room
          and rp.player_id=i.target_player_id
          and rp.status<>'left'
      );
  end if;
end;
$function$;

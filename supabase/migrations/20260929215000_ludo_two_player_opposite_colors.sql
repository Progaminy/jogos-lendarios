-- Ludo 2 jogadores: as duas cores devem permanecer sempre em casas opostas.
-- Pares válidos: red <-> yellow e green <-> blue.
-- Corrige tanto a entrada na sala como a troca manual de cor.

create or replace function public.jl_ludo_choose_color(
  p_token text,
  p_room uuid,
  p_color text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  me uuid := public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  rp public.ludo_room_players%rowtype;
  opponent public.ludo_room_players%rowtype;
  wanted text := lower(trim(coalesce(p_color,'')));
  opposite_color text;
  temp_color text;
  old_self_color text;
  old_opponent_color text;
begin
  if wanted not in ('red','green','yellow','blue') then
    raise exception 'Cor inválida.';
  end if;

  select * into r
  from public.ludo_rooms
  where id = p_room
  for update;

  if r.id is null or r.status not in ('waiting','negotiating') then
    raise exception 'A cor só pode ser escolhida antes da confirmação da partida.';
  end if;

  -- Serializa todas as escolhas de cor desta sala.
  perform 1
  from public.ludo_room_players x
  where x.room_id=p_room
    and x.status<>'left'
  order by x.seat
  for update;

  select * into rp
  from public.ludo_room_players
  where room_id = p_room
    and player_id = me
    and status <> 'left';

  if rp.player_id is null then
    raise exception 'Jogador não pertence a esta sala.';
  end if;

  old_self_color:=rp.color;

  if r.player_count=2 then
    opposite_color:=case wanted
      when 'red' then 'yellow'
      when 'yellow' then 'red'
      when 'green' then 'blue'
      when 'blue' then 'green'
    end;

    select * into opponent
    from public.ludo_room_players x
    where x.room_id=p_room
      and x.player_id<>me
      and x.status<>'left'
    order by x.seat
    limit 1;

    if opponent.player_id is null then
      if rp.color<>wanted then
        update public.ludo_room_players
        set color=wanted
        where room_id=p_room and player_id=me;
      end if;
    else
      old_opponent_color:=opponent.color;

      if rp.color<>wanted or opponent.color<>opposite_color then
        -- A unique(room_id,color) impede uma troca direta quando os jogadores
        -- estão a permutar as duas cores. Nesses casos usamos uma das duas
        -- cores livres como posição temporária, sempre antes da partida.
        if wanted=opponent.color or opposite_color=rp.color then
          select c into temp_color
          from unnest(array['red','green','yellow','blue']::text[]) as c
          where c<>rp.color
            and c<>opponent.color
            and c<>wanted
            and c<>opposite_color
          limit 1;

          if temp_color is null then
            -- Para dois jogadores este ramo é apenas defensivo; normalmente
            -- sempre existe pelo menos uma cor livre para a troca.
            select c into temp_color
            from unnest(array['red','green','yellow','blue']::text[]) as c
            where c<>opponent.color
              and c<>wanted
              and c<>opposite_color
            limit 1;
          end if;

          if temp_color is null then
            raise exception 'Não foi possível reorganizar as cores da partida.';
          end if;

          update public.ludo_room_players
          set color=temp_color
          where room_id=p_room and player_id=me;
        elseif rp.color<>wanted then
          update public.ludo_room_players
          set color=wanted
          where room_id=p_room and player_id=me;
        end if;

        if opponent.color<>opposite_color then
          update public.ludo_room_players
          set color=opposite_color
          where room_id=p_room and player_id=opponent.player_id;
        end if;

        update public.ludo_room_players
        set color=wanted
        where room_id=p_room
          and player_id=me
          and color<>wanted;
      end if;
    end if;

    perform public.jl_ludo_event(
      p_room,
      me,
      'color_selected',
      jsonb_build_object(
        'from',old_self_color,
        'to',wanted,
        'two_player_opposite',true,
        'opponent_from',old_opponent_color,
        'opponent_to',case when opponent.player_id is null then null else opposite_color end
      )
    );

    return public.jl_ludo_room_state(p_token,p_room);
  end if;

  if rp.color = wanted then
    return public.jl_ludo_room_state(p_token,p_room);
  end if;

  if exists (
    select 1
    from public.ludo_room_players x
    where x.room_id = p_room
      and x.player_id <> me
      and x.status <> 'left'
      and x.color = wanted
  ) then
    raise exception 'Esta cor já está ocupada.';
  end if;

  update public.ludo_room_players
  set color = wanted
  where room_id = p_room
    and player_id = me;

  perform public.jl_ludo_event(
    p_room,
    me,
    'color_selected',
    jsonb_build_object('from',old_self_color,'to',wanted)
  );

  return public.jl_ludo_room_state(p_token,p_room);
end;
$function$;

revoke execute on function public.jl_ludo_choose_color(text,uuid,text) from public;
revoke execute on function public.jl_ludo_choose_color(text,uuid,text) from anon, authenticated;
grant execute on function public.jl_ludo_choose_color(text,uuid,text) to anon, authenticated;


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
    select 1 from public.ludo_room_players
    where room_id=p_room and player_id=p_player and status<>'left'
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
    where room_id=p_room and status<>'left'
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
    col:=case s
      when 1 then 'red'
      when 2 then 'green'
      when 3 then 'yellow'
      else 'blue'
    end;
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

create or replace function public.jl_dama_accept_settings(p_token text,p_room uuid,p_accept boolean default true)
returns jsonb language plpgsql security definer set search_path='public' as $$
declare me uuid:=public.jl_player_id(p_token); r public.dama_rooms%rowtype; rp public.dama_room_players%rowtype; firstp uuid;
begin
  select * into r from public.dama_rooms where id=p_room for update;
  select * into rp from public.dama_room_players where room_id=p_room and player_id=me and status<>'left' for update;
  if r.id is null or rp.player_id is null or r.status<>'negotiating' then raise exception 'Partida indisponível para aceitação.'; end if;
  if r.play_mode='free' then perform public.jl_free_access_require(me); end if;
  if me=r.host_id then return public.jl_dama_room_state(p_token,p_room); end if;
  if not coalesce(p_accept,true) then
    delete from public.dama_room_players where room_id=p_room and player_id=me;
    update public.dama_rooms set guest_id=null,status='waiting',updated_at=now() where id=p_room;
    perform public.jl_dama_event(p_room,me,'settings_declined','{}'::jsonb);
    return jsonb_build_object('ok',true,'accepted',false);
  end if;
  update public.dama_room_players set settings_accepted=true where room_id=p_room and player_id=me;
  if r.play_mode='free' then
    if not public.jl_free_access_active(r.host_id) then raise exception 'O criador precisa de FREE ativo.'; end if;
    update public.dama_room_players set stake_paid=true,stake_amount=0 where room_id=p_room and status<>'left';
    perform public.jl_dama_init_board(p_room);
    firstp:=case r.first_player_choice when 'host' then r.host_id else r.guest_id end;
    update public.dama_rooms set status='ready',current_player_id=firstp,started_at=null,action_deadline=null,board_version=0,move_seq=0,quiet_king_moves=0,regulation_key=null,regulation_moves=0,regulation_limit=0,pot=0,updated_at=now() where id=p_room;
    perform public.jl_dama_event(p_room,firstp,'game_ready',jsonb_build_object('first_player',firstp,'timer_starts_after_first_move',true,'free',true));
    insert into public.dama_positions(room_id,position_key,occurrences)
    values(p_room,public.jl_dama_position_key(p_room,firstp),1)
    on conflict(room_id,position_key) do update set occurrences=public.dama_positions.occurrences+1,updated_at=now();
  else
    update public.dama_rooms set status='funding',updated_at=now() where id=p_room;
    perform public.jl_dama_event(p_room,me,'settings_accepted',jsonb_build_object('bet_amount',r.bet_amount,'turn_seconds',r.turn_seconds,'host_color',r.host_color,'first_player',r.first_player_choice));
  end if;
  return public.jl_dama_room_state(p_token,p_room);
end; $$;

create or replace function public.jl_dama_public_rooms(p_token text)
returns jsonb language plpgsql security definer set search_path='public' as $$
declare me uuid:=public.jl_player_id(p_token);
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'code',r.code,'host_id',r.host_id,'host_name',p.name,'host_code',public.jl_ludo_display_code(r.host_id),'bet_amount',r.bet_amount,'turn_seconds',r.turn_seconds,'host_color',r.host_color,'first_player',r.first_player_choice,'created_at',r.created_at) order by r.created_at desc)
    from public.dama_rooms r join public.players p on p.id=r.host_id
    where r.play_mode='bet' and r.is_public and r.status='waiting' and r.host_id<>me),'[]'::jsonb);
end; $$;

create or replace function public.jl_dama_join_room(p_token text,p_code text)
returns jsonb language plpgsql security definer set search_path='public' as $$
declare me uuid:=public.jl_player_id(p_token); r public.dama_rooms%rowtype; guest_color text;
begin
  select * into r from public.dama_rooms where upper(code)=upper(trim(p_code)) and play_mode='bet' for update;
  if r.id is null or r.status<>'waiting' or r.guest_id is not null then raise exception 'Sala de Dama indisponível.'; end if;
  if r.host_id=me then raise exception 'Você já criou esta sala.'; end if;
  if exists(select 1 from public.dama_room_players rp join public.dama_rooms rr on rr.id=rp.room_id where rp.player_id=me and rp.status<>'left' and rr.status in ('waiting','negotiating','funding','ready','playing')) then raise exception 'Você já participa de uma partida de Dama ativa.'; end if;
  guest_color:=case r.host_color when 'white' then 'red' else 'white' end;
  update public.dama_rooms set guest_id=me,status='negotiating',updated_at=now() where id=r.id;
  insert into public.dama_room_players(room_id,player_id,seat,color,settings_accepted) values(r.id,me,2,guest_color,false);
  perform public.jl_dama_event(r.id,me,'player_joined',jsonb_build_object('color',guest_color));
  return public.jl_dama_room_state(p_token,r.id);
end; $$;

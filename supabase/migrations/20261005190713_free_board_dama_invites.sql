create or replace function public.jl_dama_create_free_from_board_invite(
  p_token text,p_board_invite uuid,p_turn_seconds integer,p_host_color text,p_first_player text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid:=public.jl_player_id(p_token); inv public.board_invitations%rowtype; other uuid; created jsonb; rid uuid; guest_color text;
begin
  perform public.jl_free_access_require(me);
  select * into inv from public.board_invitations where id=p_board_invite for update;
  if inv.id is null or inv.status<>'accepted' or inv.selected_game<>'dama' or (inv.sender_id<>me and inv.target_id<>me) then raise exception 'Convite global de Dama inválido.'; end if;
  other:=case when inv.sender_id=me then inv.target_id else inv.sender_id end;
  perform public.jl_free_access_require(other);
  created:=public.jl_dama_create_free_room(p_token,p_turn_seconds,p_host_color,p_first_player,false);
  rid:=(created->'room'->>'id')::uuid;
  guest_color:=case lower(p_host_color) when 'white' then 'red' else 'white' end;
  update public.dama_rooms set guest_id=other,status='negotiating',updated_at=now() where id=rid;
  insert into public.dama_room_players(room_id,player_id,seat,color,settings_accepted,stake_paid,stake_amount)
  values(rid,other,2,guest_color,false,false,0);
  update public.board_invitations set status='consumed',consumed_at=now() where id=p_board_invite;
  perform public.jl_dama_event(rid,me,'board_invite_attached',jsonb_build_object('board_invite',p_board_invite,'opponent',other,'free',true));
  perform public.jl_notification_create(other,'dama-invite','Desafio FREE de Dama','Partida sem aposta.','./dama.html?mode=free&room='||rid::text,'dama-free-board-invite:'||rid::text);
  return public.jl_dama_room_state(p_token,rid);
end; $$;

create or replace function public.jl_dama_free_rematch(
  p_token text,p_room uuid,p_turn_seconds integer,p_host_color text,p_first_player text,p_is_public boolean default false
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid:=public.jl_player_id(p_token); old public.dama_rooms%rowtype; opponent uuid; created jsonb; new_room uuid; guest_color text;
begin
  perform public.jl_free_access_require(me);
  select * into old from public.dama_rooms where id=p_room for update;
  if old.id is null or old.status<>'finished' or old.play_mode<>'free' or not public.jl_dama_is_member(p_room,me) then raise exception 'Partida FREE anterior indisponível.'; end if;
  select player_id into opponent from public.dama_room_players where room_id=p_room and player_id<>me order by seat limit 1;
  perform public.jl_free_access_require(opponent);
  created:=public.jl_dama_create_free_room(p_token,p_turn_seconds,p_host_color,p_first_player,p_is_public);
  new_room:=(created->'room'->>'id')::uuid;
  guest_color:=case lower(p_host_color) when 'white' then 'red' else 'white' end;
  update public.dama_rooms set guest_id=opponent,status='negotiating',updated_at=now() where id=new_room;
  insert into public.dama_room_players(room_id,player_id,seat,color,settings_accepted,stake_paid,stake_amount)
  values(new_room,opponent,2,guest_color,false,false,0);
  perform public.jl_dama_event(new_room,me,'rematch_proposed',jsonb_build_object('previous_room',p_room,'opponent',opponent,'free',true));
  perform public.jl_notification_create(opponent,'dama-invite','Revanche FREE de Dama','Partida sem aposta.','./dama.html?mode=free&room='||new_room::text,'dama-free-rematch:'||new_room::text);
  return public.jl_dama_room_state(p_token,new_room);
end; $$;

revoke execute on function public.jl_dama_create_free_from_board_invite(text,uuid,integer,text,text) from public;
revoke execute on function public.jl_dama_free_rematch(text,uuid,integer,text,text,boolean) from public;
grant execute on function public.jl_dama_create_free_from_board_invite(text,uuid,integer,text,text) to anon,authenticated;
grant execute on function public.jl_dama_free_rematch(text,uuid,integer,text,text,boolean) to anon,authenticated;

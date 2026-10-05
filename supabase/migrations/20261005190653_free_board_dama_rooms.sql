create or replace function public.jl_dama_create_free_room(
  p_token text,p_turn_seconds integer default 120,p_host_color text default 'white',p_first_player text default 'host',p_is_public boolean default false
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid:=public.jl_player_id(p_token); r public.dama_rooms%rowtype; color text:=lower(trim(coalesce(p_host_color,'white'))); firstp text:=lower(trim(coalesce(p_first_player,'host')));
begin
  perform public.jl_free_access_require(me);
  if not public.jl_dama_turn_seconds_allowed(p_turn_seconds) then raise exception 'Tempo de jogada não permitido.'; end if;
  if color not in ('white','red') then raise exception 'Cor inválida.'; end if;
  if firstp not in ('host','guest') then raise exception 'Quem começa é inválido.'; end if;
  if exists(select 1 from public.dama_room_players rp join public.dama_rooms x on x.id=rp.room_id where rp.player_id=me and rp.status<>'left' and x.status in ('waiting','negotiating','funding','ready','playing')) then raise exception 'Você já participa de uma partida de Dama ativa.'; end if;
  insert into public.dama_rooms(code,host_id,bet_amount,turn_seconds,host_color,first_player_choice,is_public,status,pot,play_mode)
  values(public.jl_dama_room_code(),me,0,p_turn_seconds,color,firstp,coalesce(p_is_public,false),'waiting',0,'free') returning * into r;
  insert into public.dama_room_players(room_id,player_id,seat,color,settings_accepted,stake_paid,stake_amount)
  values(r.id,me,1,color,true,true,0);
  perform public.jl_dama_event(r.id,me,'room_created',jsonb_build_object('free',true,'turn_seconds',p_turn_seconds,'host_color',color,'first_player',firstp,'public',p_is_public));
  return public.jl_dama_room_state(p_token,r.id);
end; $$;

create or replace function public.jl_dama_free_public_rooms(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid:=public.jl_player_id(p_token);
begin
  perform public.jl_free_access_require(me);
  return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'code',r.code,'host_id',r.host_id,'host_name',p.name,'host_code',public.jl_ludo_display_code(r.host_id),'bet_amount',0,'play_mode','free','turn_seconds',r.turn_seconds,'host_color',r.host_color,'first_player',r.first_player_choice,'created_at',r.created_at) order by r.created_at desc)
    from public.dama_rooms r join public.players p on p.id=r.host_id
    where r.play_mode='free' and r.is_public and r.status='waiting' and r.host_id<>me),'[]'::jsonb);
end; $$;

create or replace function public.jl_dama_join_free_room(p_token text,p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid:=public.jl_player_id(p_token); r public.dama_rooms%rowtype; guest_color text;
begin
  perform public.jl_free_access_require(me);
  select * into r from public.dama_rooms where upper(code)=upper(trim(p_code)) and play_mode='free' for update;
  if r.id is null or r.status<>'waiting' or r.guest_id is not null then raise exception 'Sala FREE de Dama indisponível.'; end if;
  if r.host_id=me then raise exception 'Você já criou esta sala.'; end if;
  if exists(select 1 from public.dama_room_players rp join public.dama_rooms rr on rr.id=rp.room_id where rp.player_id=me and rp.status<>'left' and rr.status in ('waiting','negotiating','funding','ready','playing')) then raise exception 'Você já participa de uma partida de Dama ativa.'; end if;
  guest_color:=case r.host_color when 'white' then 'red' else 'white' end;
  update public.dama_rooms set guest_id=me,status='negotiating',updated_at=now() where id=r.id;
  insert into public.dama_room_players(room_id,player_id,seat,color,settings_accepted,stake_paid,stake_amount)
  values(r.id,me,2,guest_color,false,false,0);
  perform public.jl_dama_event(r.id,me,'player_joined',jsonb_build_object('color',guest_color,'free',true));
  return public.jl_dama_room_state(p_token,r.id);
end; $$;

revoke execute on function public.jl_dama_create_free_room(text,integer,text,text,boolean) from public;
revoke execute on function public.jl_dama_free_public_rooms(text) from public;
revoke execute on function public.jl_dama_join_free_room(text,text) from public;
grant execute on function public.jl_dama_create_free_room(text,integer,text,text,boolean) to anon,authenticated;
grant execute on function public.jl_dama_free_public_rooms(text) to anon,authenticated;
grant execute on function public.jl_dama_join_free_room(text,text) to anon,authenticated;

-- Melhoria 5: escolha de jogadores, microfone e captura.
-- Em partidas de 2 jogadores, ignorar captura nunca elimina.

create or replace function public.jl_ludo_apply_capture_penalty(p_room uuid, p_player uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare r public.ludo_rooms%rowtype; pen text; secs int;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  pen:=r.rules->>'capture_penalty';
  if r.player_count=2 then pen:='lose_turn'; end if;
  if pen='lose_turn' then
    perform public.jl_ludo_event(p_room,p_player,'capture_required_missed',jsonb_build_object('penalty','lose_turn'));
    perform public.jl_ludo_advance_turn(p_room,p_player,false);
  elsif pen='eliminate' or not (r.rules->>'reentry_allowed')::boolean then
    update public.ludo_room_players set status='eliminated',reentry_deadline=null where room_id=p_room and player_id=p_player;
    perform public.jl_ludo_event(p_room,p_player,'player_eliminated',jsonb_build_object('reason','capture_required'));
    perform public.jl_ludo_advance_turn(p_room,p_player,false);
  else
    secs:=(r.rules->>'reentry_seconds')::int;
    update public.ludo_room_players set status='reentry',reentry_deadline=now()+make_interval(secs=>secs) where room_id=p_room and player_id=p_player;
    perform public.jl_ludo_event(p_room,p_player,'reentry_required',jsonb_build_object('reason','capture_required','amount',(r.rules->>'reentry_amount')::numeric,'deadline',now()+make_interval(secs=>secs)));
    perform public.jl_ludo_advance_turn(p_room,p_player,false);
  end if;
  return pen;
end;
$$;

update public.ludo_rooms
set rules=jsonb_set(rules,'{capture_penalty}','"lose_turn"'::jsonb,true),updated_at=now()
where player_count=2
  and status in ('waiting','negotiating','funding','playing')
  and coalesce(rules->>'capture_penalty','')<>'lose_turn';

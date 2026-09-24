create or replace function public.jl_ludo_accept_public_challenge(p_token text,p_code text) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := public.jl_player_id(p_token);
  target public.ludo_rooms%rowtype;
  current_room public.ludo_rooms%rowtype;
  current_id uuid;
  joined int;
begin
  select * into target
  from public.ludo_rooms
  where upper(code)=upper(trim(p_code))
    and is_public
    and status in ('waiting','negotiating')
  for update;

  if target.id is null then raise exception 'Desafio público não encontrado.'; end if;
  select count(*) into joined from public.ludo_room_players where room_id=target.id and status<>'left';
  if joined >= target.player_count then raise exception 'Este desafio já está completo.'; end if;

  select r.id into current_id
  from public.ludo_room_players rp
  join public.ludo_rooms r on r.id=rp.room_id
  where rp.player_id=me and rp.status<>'left' and r.status in ('waiting','negotiating','funding','playing')
  order by r.created_at desc limit 1;

  if current_id = target.id then return public.jl_ludo_room_state(p_token,target.id); end if;

  if current_id is not null then
    select * into current_room from public.ludo_rooms where id=current_id for update;
    if current_room.status not in ('waiting','negotiating') then
      raise exception 'Você já está numa partida que não pode ser trocada agora.';
    end if;

    select count(*) into joined from public.ludo_room_players where room_id=current_id and status<>'left';
    if current_room.host_id=me then
      if joined>1 then raise exception 'Sua sala atual já tem outros jogadores. Saia dela antes de aceitar outro desafio.'; end if;
      update public.ludo_invitations set status='cancelled' where room_id=current_id and status='pending';
      update public.ludo_room_players set status='left' where room_id=current_id and player_id=me;
      update public.ludo_rooms set status='cancelled',action_deadline=null,updated_at=now() where id=current_id;
    else
      update public.ludo_room_players set status='left' where room_id=current_id and player_id=me;
    end if;
  end if;

  perform public.jl_ludo_join_room_internal(target.id,me);
  delete from public.ludo_waiting_queue where player_id=me;
  perform public.jl_ludo_event(target.id,me,'public_challenge_accepted',jsonb_build_object('code',target.code));
  return public.jl_ludo_room_state(p_token,target.id);
end; $$;

revoke execute on function public.jl_ludo_accept_public_challenge(text,text) from public;
grant execute on function public.jl_ludo_accept_public_challenge(text,text) to anon, authenticated;

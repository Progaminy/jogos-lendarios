-- Melhoria 11: presença online, contadores e troca da própria sala por convite.

alter table public.player_sessions
add column if not exists last_seen_at timestamptz not null default now();

create index if not exists player_sessions_last_seen_idx
on public.player_sessions(last_seen_at desc);

create or replace function public.jl_ludo_my_status(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare me uuid:=public.jl_player_id(p_token); rid uuid; online_total int;
begin
  perform public.jl_ludo_ensure_code(me);
  update public.player_sessions
  set last_seen_at=now()
  where token_hash=public.jl_token_hash(p_token) and expires_at>now();

  delete from public.ludo_waiting_queue where expires_at<=now();

  select count(distinct player_id) into online_total
  from public.player_sessions
  where expires_at>now() and last_seen_at>=now()-interval '20 seconds';

  select r.id into rid
  from public.ludo_room_players rp
  join public.ludo_rooms r on r.id=rp.room_id
  where rp.player_id=me and rp.status<>'left'
    and r.status in ('waiting','negotiating','funding','playing')
  order by r.created_at desc limit 1;

  return jsonb_build_object(
    'identity',jsonb_build_object(
      'player_id',me,
      'name',(select name from public.players where id=me),
      'code',public.jl_ludo_display_code(me),
      'house_number',(select house_number from public.ludo_player_codes where player_id=me),
      'balance',(select balance from public.players where id=me)
    ),
    'active_room_id',rid,
    'online_count',online_total,
    'queue',(select case when w.player_id is null then null else to_jsonb(w) end from public.ludo_waiting_queue w where w.player_id=me),
    'invites',public.jl_ludo_my_invites(p_token)
  );
end;
$$;

create or replace function public.jl_ludo_accept_invite(p_token text,p_invitation uuid,p_accept boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  i public.ludo_invitations%rowtype;
  target_room public.ludo_rooms%rowtype;
  current_room public.ludo_rooms%rowtype;
  current_id uuid;
  replacement_host uuid;
  others_count int;
begin
  select * into i from public.ludo_invitations
  where id=p_invitation and target_player_id=me for update;
  if i.id is null then raise exception 'Convite não encontrado.'; end if;

  select * into target_room from public.ludo_rooms where id=i.room_id for update;

  if not p_accept then
    if i.status='pending' then update public.ludo_invitations set status='declined' where id=i.id; end if;
    return jsonb_build_object('ok',true,'accepted',false,'status','declined');
  end if;

  if i.status not in ('pending','accepted') then raise exception 'Este convite já não está disponível.'; end if;
  if target_room.id is null or target_room.status not in ('waiting','negotiating') then raise exception 'A sala deste convite já não está disponível.'; end if;

  if exists(select 1 from public.ludo_room_players where room_id=i.room_id and player_id=me and status<>'left') then
    if i.status='pending' then update public.ludo_invitations set status='accepted' where id=i.id; end if;
    return public.jl_ludo_room_state(p_token,i.room_id);
  end if;

  select r.id into current_id
  from public.ludo_room_players rp
  join public.ludo_rooms r on r.id=rp.room_id
  where rp.player_id=me and rp.status<>'left'
    and r.status in ('waiting','negotiating','funding','playing')
    and r.id<>i.room_id
  order by r.created_at desc limit 1;

  if current_id is not null then
    select * into current_room from public.ludo_rooms where id=current_id for update;

    if current_room.host_id<>me or current_room.status not in ('waiting','negotiating') then
      raise exception 'Termine ou saia da sala atual antes de aceitar este convite.';
    end if;

    select count(*) into others_count
    from public.ludo_room_players
    where room_id=current_id and status<>'left' and player_id<>me;

    if others_count=0 then
      update public.ludo_invitations set status='cancelled'
      where room_id=current_id and status='pending';
      update public.ludo_room_players set status='left'
      where room_id=current_id and player_id=me;
      update public.ludo_rooms
      set status='cancelled',action_deadline=null,updated_at=now()
      where id=current_id;
      perform public.jl_ludo_event(current_id,me,'host_switched_to_invited_room',
        jsonb_build_object('cancelled_empty_room',true,'target_room',i.room_id));
    else
      select player_id into replacement_host
      from public.ludo_room_players
      where room_id=current_id and status<>'left' and player_id<>me
      order by seat limit 1;

      update public.ludo_room_players set status='left'
      where room_id=current_id and player_id=me;
      update public.ludo_rooms
      set host_id=replacement_host,status='waiting',action_deadline=null,
          negotiation_grace_used=false,updated_at=now()
      where id=current_id;

      perform public.jl_ludo_event(current_id,me,'host_transferred_for_invite',
        jsonb_build_object('new_host',replacement_host,'target_room',i.room_id));
    end if;
  end if;

  perform public.jl_ludo_join_room_internal(i.room_id,me);

  if not exists(select 1 from public.ludo_room_players
                where room_id=i.room_id and player_id=me and status<>'left') then
    raise exception 'Não foi possível concluir a entrada na sala convidada.';
  end if;

  update public.ludo_invitations set status='accepted' where id=i.id;
  delete from public.ludo_waiting_queue where player_id=me;
  return public.jl_ludo_room_state(p_token,i.room_id);
end;
$$;

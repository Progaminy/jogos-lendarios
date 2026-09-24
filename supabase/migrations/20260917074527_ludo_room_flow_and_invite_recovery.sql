create or replace function public.jl_ludo_accept_invite(p_token text,p_invitation uuid,p_accept boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := public.jl_player_id(p_token);
  i public.ludo_invitations%rowtype;
  r public.ludo_rooms%rowtype;
begin
  select * into i
  from public.ludo_invitations
  where id=p_invitation and target_player_id=me
  for update;

  if i.id is null then raise exception 'Convite não encontrado.'; end if;

  select * into r from public.ludo_rooms where id=i.room_id;

  if not p_accept then
    if i.status='pending' then
      update public.ludo_invitations set status='declined' where id=i.id;
    end if;
    return jsonb_build_object('ok',true,'accepted',false,'status','declined');
  end if;

  if i.status='accepted' then
    if exists(select 1 from public.ludo_room_players where room_id=i.room_id and player_id=me and status<>'left') then
      return public.jl_ludo_room_state(p_token,i.room_id);
    end if;
    if r.id is null or r.status not in ('waiting','negotiating') then
      raise exception 'A sala deste convite já não está disponível.';
    end if;
    perform public.jl_ludo_join_room_internal(i.room_id,me);
    if not exists(select 1 from public.ludo_room_players where room_id=i.room_id and player_id=me and status<>'left') then
      raise exception 'Não foi possível concluir a entrada na sala.';
    end if;
    delete from public.ludo_waiting_queue where player_id=me;
    perform public.jl_ludo_event(i.room_id,me,'accepted_invite_recovered',jsonb_build_object('invitation_id',i.id));
    return public.jl_ludo_room_state(p_token,i.room_id);
  end if;

  if i.status<>'pending' then
    raise exception 'Este convite já não está pendente.';
  end if;

  if i.expires_at<=now() then
    update public.ludo_invitations set status='expired' where id=i.id;
    return jsonb_build_object('ok',false,'accepted',false,'expired',true,'status','expired');
  end if;

  perform public.jl_ludo_join_room_internal(i.room_id,me);
  if not exists(select 1 from public.ludo_room_players where room_id=i.room_id and player_id=me and status<>'left') then
    raise exception 'Não foi possível concluir a entrada na sala.';
  end if;
  update public.ludo_invitations set status='accepted' where id=i.id;
  delete from public.ludo_waiting_queue where player_id=me;
  return public.jl_ludo_room_state(p_token,i.room_id);
end;
$$;

create or replace function public.jl_ludo_my_invites(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare me uuid := public.jl_player_id(p_token);
begin
  update public.ludo_invitations
  set status='expired'
  where target_player_id=me and status='pending' and expires_at<=now();

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',i.id,
      'room_id',i.room_id,
      'room_code',r.code,
      'host',p.name,
      'host_code',public.jl_ludo_display_code(r.host_id),
      'bet_amount',r.bet_amount,
      'player_count',r.player_count,
      'mode',r.mode,
      'expires_at',i.expires_at,
      'status',i.status,
      'recoverable',(i.status='accepted')
    ) order by i.created_at desc)
    from public.ludo_invitations i
    join public.ludo_rooms r on r.id=i.room_id
    join public.players p on p.id=r.host_id
    where i.target_player_id=me
      and (
        (i.status='pending' and i.expires_at>now())
        or
        (i.status='accepted'
          and r.status in ('waiting','negotiating')
          and not exists(select 1 from public.ludo_room_players rp where rp.room_id=i.room_id and rp.player_id=me and rp.status<>'left')
          and (select count(*) from public.ludo_room_players rp2 where rp2.room_id=i.room_id and rp2.status<>'left') < r.player_count)
      )
  ),'[]'::jsonb);
end;
$$;

create or replace function public.jl_ludo_room_invites(p_token text,p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
begin
  select * into r from public.ludo_rooms where id=p_room;
  if r.id is null or not public.jl_ludo_is_member(p_room,me) then raise exception 'Sala inválida.'; end if;

  update public.ludo_invitations
  set status='expired'
  where room_id=p_room and status='pending' and expires_at<=now();

  return jsonb_build_object(
    'public_challenge_expires_at',r.public_challenge_expires_at,
    'items',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',i.id,
        'target_player_id',i.target_player_id,
        'name',p.name,
        'code',public.jl_ludo_display_code(i.target_player_id),
        'status',i.status,
        'created_at',i.created_at,
        'expires_at',i.expires_at,
        'joined',exists(select 1 from public.ludo_room_players rp where rp.room_id=p_room and rp.player_id=i.target_player_id and rp.status<>'left')
      ) order by i.created_at desc)
      from public.ludo_invitations i
      join public.players p on p.id=i.target_player_id
      where i.room_id=p_room
    ),'[]'::jsonb)
  );
end;
$$;

revoke execute on function public.jl_ludo_accept_invite(text,uuid,boolean) from public;
revoke execute on function public.jl_ludo_my_invites(text) from public;
revoke execute on function public.jl_ludo_room_invites(text,uuid) from public;
grant execute on function public.jl_ludo_accept_invite(text,uuid,boolean) to anon, authenticated;
grant execute on function public.jl_ludo_my_invites(text) to anon, authenticated;
grant execute on function public.jl_ludo_room_invites(text,uuid) to anon, authenticated;

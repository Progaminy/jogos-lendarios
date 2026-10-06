-- Make Ludo direct invitations explicitly distinguish FREE rooms.
create or replace function public.jl_ludo_my_invites(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare me uuid := public.jl_player_id(p_token);
begin
 return coalesce((select jsonb_agg(jsonb_build_object(
   'id',i.id,'room_id',i.room_id,'room_code',r.code,'host',p.name,'host_code',public.jl_ludo_display_code(r.host_id),
   'bet_amount',r.bet_amount,'player_count',r.player_count,'mode',r.mode,'play_mode',r.play_mode,
   'expires_at',null,'status',i.status,'recoverable',(i.status='accepted')
 ) order by i.created_at desc)
 from public.ludo_invitations i
 join public.ludo_rooms r on r.id=i.room_id
 join public.players p on p.id=r.host_id
 where i.target_player_id=me and ((i.status='pending' and r.status in ('waiting','negotiating')) or (i.status='accepted' and r.status in ('waiting','negotiating') and not exists(select 1 from public.ludo_room_players rp where rp.room_id=i.room_id and rp.player_id=me and rp.status<>'left') and (select count(*) from public.ludo_room_players rp2 where rp2.room_id=i.room_id and rp2.status<>'left') < r.player_count))),'[]'::jsonb);
end; $function$;

create or replace function public.jl_ludo_accept_invite(p_token text, p_invitation uuid, p_accept boolean default true)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  me uuid:=public.jl_player_id(p_token);
  i public.ludo_invitations%rowtype;
  target_room public.ludo_rooms%rowtype;
  current_room public.ludo_rooms%rowtype;
  current_id uuid;
  replacement_host uuid;
  others_count int;
begin
  select * into i from public.ludo_invitations where id=p_invitation and target_player_id=me for update;
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
  if target_room.play_mode='bet' then perform public.jl_require_cash_balance(me,target_room.bet_amount); end if;
  perform public.jl_ludo_join_room_internal(i.room_id,me);
  if not exists(select 1 from public.ludo_room_players where room_id=i.room_id and player_id=me and status<>'left') then raise exception 'Não foi possível concluir a entrada na sala convidada.'; end if;
  update public.ludo_invitations set status='accepted' where id=i.id;
  delete from public.ludo_waiting_queue where player_id=me;
  return public.jl_ludo_room_state(p_token,i.room_id);
end; $function$;
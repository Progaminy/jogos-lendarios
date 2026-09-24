alter table public.ludo_invitations alter column expires_at drop not null;

create or replace function public.jl_ludo_invite(p_token text, p_room uuid, p_target_player uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare me uuid := public.jl_player_id(p_token); r public.ludo_rooms%rowtype; inv uuid;
begin
 select * into r from public.ludo_rooms where id=p_room for update;
 if r.id is null or r.host_id<>me then raise exception 'Apenas o anfitrião pode convidar.'; end if;
 if r.status not in ('waiting','negotiating') then raise exception 'A sala não aceita novos jogadores neste momento.'; end if;
 if p_target_player=me or not exists(select 1 from public.players where id=p_target_player and not blocked) then raise exception 'Jogador inválido.'; end if;
 if (select count(*) from public.ludo_room_players where room_id=p_room and status<>'left') >= r.player_count then raise exception 'Sala cheia.'; end if;
 update public.ludo_invitations set status='cancelled' where room_id=p_room and target_player_id=p_target_player and status='pending';
 insert into public.ludo_invitations(room_id,invited_by,target_player_id,expires_at) values(p_room,me,p_target_player,null) returning id into inv;
 perform public.jl_ludo_event(p_room,me,'invite_sent',jsonb_build_object('target',p_target_player));
 return jsonb_build_object('ok',true,'invitation_id',inv,'expires_at',null);
end; $$;

create or replace function public.jl_ludo_accept_invite(p_token text, p_invitation uuid, p_accept boolean default true)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare me uuid := public.jl_player_id(p_token); i public.ludo_invitations%rowtype; r public.ludo_rooms%rowtype;
begin
 select * into i from public.ludo_invitations where id=p_invitation and target_player_id=me for update;
 if i.id is null then raise exception 'Convite não encontrado.'; end if;
 select * into r from public.ludo_rooms where id=i.room_id;
 if not p_accept then
   if i.status='pending' then update public.ludo_invitations set status='declined' where id=i.id; end if;
   return jsonb_build_object('ok',true,'accepted',false,'status','declined');
 end if;
 if i.status='accepted' then
   if exists(select 1 from public.ludo_room_players where room_id=i.room_id and player_id=me and status<>'left') then return public.jl_ludo_room_state(p_token,i.room_id); end if;
   if r.id is null or r.status not in ('waiting','negotiating') then raise exception 'A sala deste convite já não está disponível.'; end if;
   perform public.jl_ludo_join_room_internal(i.room_id,me);
   delete from public.ludo_waiting_queue where player_id=me;
   return public.jl_ludo_room_state(p_token,i.room_id);
 end if;
 if i.status<>'pending' then raise exception 'Este convite já não está pendente.'; end if;
 if r.id is null or r.status not in ('waiting','negotiating') then raise exception 'A sala deste convite já não está disponível.'; end if;
 perform public.jl_ludo_join_room_internal(i.room_id,me);
 if not exists(select 1 from public.ludo_room_players where room_id=i.room_id and player_id=me and status<>'left') then raise exception 'Não foi possível concluir a entrada na sala.'; end if;
 update public.ludo_invitations set status='accepted' where id=i.id;
 delete from public.ludo_waiting_queue where player_id=me;
 return public.jl_ludo_room_state(p_token,i.room_id);
end; $$;

create or replace function public.jl_ludo_my_invites(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare me uuid := public.jl_player_id(p_token);
begin
 return coalesce((select jsonb_agg(jsonb_build_object(
   'id',i.id,'room_id',i.room_id,'room_code',r.code,'host',p.name,'host_code',public.jl_ludo_display_code(r.host_id),
   'bet_amount',r.bet_amount,'player_count',r.player_count,'mode',r.mode,'expires_at',null,'status',i.status,
   'recoverable',(i.status='accepted')
 ) order by i.created_at desc)
 from public.ludo_invitations i join public.ludo_rooms r on r.id=i.room_id join public.players p on p.id=r.host_id
 where i.target_player_id=me and ((i.status='pending' and r.status in ('waiting','negotiating')) or (i.status='accepted' and r.status in ('waiting','negotiating') and not exists(select 1 from public.ludo_room_players rp where rp.room_id=i.room_id and rp.player_id=me and rp.status<>'left') and (select count(*) from public.ludo_room_players rp2 where rp2.room_id=i.room_id and rp2.status<>'left') < r.player_count))),'[]'::jsonb);
end; $$;

create or replace function public.jl_ludo_room_invites(p_token text, p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare me uuid := public.jl_player_id(p_token); r public.ludo_rooms%rowtype;
begin
 select * into r from public.ludo_rooms where id=p_room;
 if r.id is null or not public.jl_ludo_is_member(p_room,me) then raise exception 'Sala inválida.'; end if;
 return jsonb_build_object('public_challenge_expires_at',r.public_challenge_expires_at,'items',coalesce((
   select jsonb_agg(jsonb_build_object('id',i.id,'target_player_id',i.target_player_id,'name',p.name,'code',public.jl_ludo_display_code(i.target_player_id),'status',i.status,'created_at',i.created_at,'expires_at',null,'joined',exists(select 1 from public.ludo_room_players rp where rp.room_id=p_room and rp.player_id=i.target_player_id and rp.status<>'left')) order by i.created_at desc)
   from public.ludo_invitations i join public.players p on p.id=i.target_player_id where i.room_id=p_room
 ),'[]'::jsonb));
end; $$;

create or replace function public.jl_ludo_process_timeouts(p_token text, p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare me uuid:=public.jl_player_id(p_token); r public.ludo_rooms%rowtype; cur uuid; limitn int;
begin
 if not public.jl_ludo_is_member(p_room,me) then raise exception 'Você não pertence a esta sala.'; end if;
 select * into r from public.ludo_rooms where id=p_room for update;
 if r.status='negotiating' and r.action_deadline is not null and r.action_deadline<=now() then
   if not r.negotiation_grace_used then
     update public.ludo_rooms set negotiation_grace_used=true,action_deadline=now()+interval '30 seconds',updated_at=now() where id=p_room;
     perform public.jl_ludo_event(p_room,null,'negotiation_grace_started',jsonb_build_object('seconds',30));
   else
     delete from public.ludo_room_players where room_id=p_room and player_id<>r.host_id and coalesce(accepted_rules_version,0)<>r.rules_version;
     update public.ludo_rooms set status='waiting',action_deadline=null,negotiation_grace_used=false,updated_at=now() where id=p_room;
     perform public.jl_ludo_event(p_room,null,'negotiation_timeout',jsonb_build_object('grace_seconds',30));
   end if;
 elsif r.status='funding' and r.action_deadline is not null and r.action_deadline<=now() then
   delete from public.ludo_room_players where room_id=p_room and player_id<>r.host_id and not stake_paid;
   perform public.jl_ludo_refund_room(p_room,'Reembolso: tempo de confirmação da sala expirou');
   update public.ludo_room_players set accepted_rules_version=case when player_id=r.host_id then r.rules_version else null end where room_id=p_room;
   update public.ludo_rooms set status='waiting',action_deadline=null,negotiation_grace_used=false,updated_at=now() where id=p_room;
   perform public.jl_ludo_event(p_room,null,'funding_timeout','{}'::jsonb);
 elsif r.status='playing' then
   update public.ludo_room_players set status='eliminated',reentry_deadline=null where room_id=p_room and status='reentry' and reentry_deadline<=now();
   if public.jl_ludo_check_finish(p_room) then return public.jl_ludo_room_state(p_token,p_room); end if;
   if r.action_deadline is not null and r.action_deadline<=now() and r.current_player_id is not null then
     cur:=r.current_player_id; limitn:=(r.rules->>'idle_strikes_limit')::int;
     update public.ludo_room_players set timeout_strikes=timeout_strikes+1 where room_id=p_room and player_id=cur;
     perform public.jl_ludo_event(p_room,cur,'action_timeout',jsonb_build_object('phase',r.turn_phase));
     if (select timeout_strikes from public.ludo_room_players where room_id=p_room and player_id=cur)>=limitn then update public.ludo_room_players set status='eliminated' where room_id=p_room and player_id=cur; perform public.jl_ludo_event(p_room,cur,'player_eliminated',jsonb_build_object('reason','timeouts')); end if;
     perform public.jl_ludo_advance_turn(p_room,cur,false);
   end if;
 end if;
 return public.jl_ludo_room_state(p_token,p_room);
end; $$;

update public.ludo_invitations set expires_at=null where status='pending';

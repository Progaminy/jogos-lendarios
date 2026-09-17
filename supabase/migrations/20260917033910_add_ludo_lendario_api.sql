create or replace function public.jl_ludo_send_chat(p_token text,p_room uuid,p_message text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid:=public.jl_player_id(p_token); r public.ludo_rooms%rowtype; mid bigint;
begin select * into r from public.ludo_rooms where id=p_room; if r.id is null or not public.jl_ludo_is_member(p_room,me) then raise exception 'Sala inválida.'; end if; if not (r.rules->>'chat_enabled')::boolean then raise exception 'Chat desativado nesta sala.'; end if; if char_length(trim(coalesce(p_message,''))) not between 1 and 500 then raise exception 'Mensagem inválida.'; end if; insert into public.ludo_chat(room_id,player_id,message) values(p_room,me,trim(p_message)) returning id into mid; return jsonb_build_object('ok',true,'id',mid); end; $$;

create or replace function public.jl_ludo_signal_send(p_token text,p_room uuid,p_to_player uuid,p_signal_type text,p_payload jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid:=public.jl_player_id(p_token); r public.ludo_rooms%rowtype; sid bigint;
begin select * into r from public.ludo_rooms where id=p_room; if r.id is null or not public.jl_ludo_is_member(p_room,me) or not public.jl_ludo_is_member(p_room,p_to_player) then raise exception 'Sinalização de voz inválida.'; end if; if not (r.rules->>'voice_enabled')::boolean then raise exception 'Voz desativada nesta sala.'; end if; if p_signal_type not in ('offer','answer','ice','renegotiate') then raise exception 'Tipo de sinal inválido.'; end if; if octet_length(coalesce(p_payload,'{}'::jsonb)::text)>50000 then raise exception 'Sinal demasiado grande.'; end if; delete from public.ludo_signals where expires_at<=now(); insert into public.ludo_signals(room_id,from_player_id,to_player_id,signal_type,payload) values(p_room,me,p_to_player,p_signal_type,p_payload) returning id into sid; return jsonb_build_object('ok',true,'id',sid); end; $$;

create or replace function public.jl_ludo_signal_pull(p_token text,p_room uuid,p_after_id bigint default 0) returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid:=public.jl_player_id(p_token); begin if not public.jl_ludo_is_member(p_room,me) then raise exception 'Sala inválida.'; end if; delete from public.ludo_signals where expires_at<=now(); return coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'from_player_id',s.from_player_id,'signal_type',s.signal_type,'payload',s.payload,'created_at',s.created_at) order by s.id) from public.ludo_signals s where s.room_id=p_room and s.to_player_id=me and s.id>coalesce(p_after_id,0) and s.expires_at>now()),'[]'::jsonb); end; $$;

create or replace function public.jl_ludo_cancel_or_leave(p_token text,p_room uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid:=public.jl_player_id(p_token); r public.ludo_rooms%rowtype; rp public.ludo_room_players%rowtype;
begin
 select * into r from public.ludo_rooms where id=p_room for update; select * into rp from public.ludo_room_players where room_id=p_room and player_id=me for update; if r.id is null or rp.player_id is null then raise exception 'Sala inválida.'; end if; if r.status in ('finished','cancelled') then return jsonb_build_object('ok',true); end if;
 if r.status<>'playing' then
   if r.host_id=me then perform public.jl_ludo_refund_room(p_room,'Reembolso: sala cancelada pelo anfitrião'); update public.ludo_rooms set status='cancelled',action_deadline=null,updated_at=now() where id=p_room; update public.ludo_room_players set status='left' where room_id=p_room;
   else if rp.stake_paid then update public.players set balance=balance+rp.stake_amount,updated_at=now() where id=me; insert into public.transactions(player_id,kind,amount,status,reference_id,note) values(me,'ludo_refund',rp.stake_amount,'completed',p_room,'Reembolso: saída antes do início'); update public.ludo_rooms set pot=greatest(0,pot-rp.stake_amount),updated_at=now() where id=p_room; end if; update public.ludo_room_players set status='left',stake_paid=false,stake_amount=0 where room_id=p_room and player_id=me; end if;
 else update public.ludo_room_players set status='eliminated' where room_id=p_room and player_id=me; perform public.jl_ludo_event(p_room,me,'player_left_game','{}'::jsonb); if r.current_player_id=me then perform public.jl_ludo_advance_turn(p_room,me,false); else perform public.jl_ludo_check_finish(p_room); end if; end if; return jsonb_build_object('ok',true);
end; $$;

create or replace function public.jl_ludo_room_state(p_token text,p_room uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid:=public.jl_player_id(p_token); r public.ludo_rooms%rowtype; mymoves jsonb:='[]'::jsonb; ident jsonb;
begin
 select * into r from public.ludo_rooms where id=p_room; if r.id is null or not public.jl_ludo_is_member(p_room,me) then raise exception 'Sala de Ludo não encontrada.'; end if; perform public.jl_ludo_ensure_code(me); if r.status='playing' and r.current_player_id=me and r.turn_phase='move' and r.dice_result is not null then mymoves:=public.jl_ludo_legal_moves_data(p_room,me,r.dice_result); end if;
 ident:=jsonb_build_object('player_id',me,'code',public.jl_ludo_display_code(me),'house_number',(select house_number from public.ludo_player_codes where player_id=me));
 return jsonb_build_object('identity',ident,'room',to_jsonb(r),
 'players',coalesce((select jsonb_agg(jsonb_build_object('player_id',rp.player_id,'name',p.name,'code',public.jl_ludo_display_code(rp.player_id),'house_number',c.house_number,'seat',rp.seat,'color',rp.color,'team',rp.team,'accepted_rules_version',rp.accepted_rules_version,'stake_paid',rp.stake_paid,'stake_amount',rp.stake_amount,'status',rp.status,'timeout_strikes',rp.timeout_strikes,'reentry_deadline',rp.reentry_deadline) order by rp.seat) from public.ludo_room_players rp join public.players p on p.id=rp.player_id join public.ludo_player_codes c on c.player_id=rp.player_id where rp.room_id=p_room and rp.status<>'left'),'[]'::jsonb),
 'tokens',coalesce((select jsonb_agg(jsonb_build_object('player_id',t.player_id,'token_no',t.token_no,'steps',t.steps) order by rp.seat,t.token_no) from public.ludo_tokens t join public.ludo_room_players rp on rp.room_id=t.room_id and rp.player_id=t.player_id where t.room_id=p_room),'[]'::jsonb), 'legal_moves',mymoves,
 'events',coalesce((select jsonb_agg(x.obj order by x.id) from (select e.id,jsonb_build_object('id',e.id,'player_id',e.player_id,'event_type',e.event_type,'payload',e.payload,'created_at',e.created_at) obj from public.ludo_events e where e.room_id=p_room order by e.id desc limit 50)x),'[]'::jsonb),
 'chat',coalesce((select jsonb_agg(x.obj order by x.id) from (select ch.id,jsonb_build_object('id',ch.id,'player_id',ch.player_id,'name',p.name,'code',public.jl_ludo_display_code(ch.player_id),'message',ch.message,'created_at',ch.created_at) obj from public.ludo_chat ch join public.players p on p.id=ch.player_id where ch.room_id=p_room order by ch.id desc limit 50)x),'[]'::jsonb),
 'payouts',coalesce((select jsonb_agg(jsonb_build_object('player_id',lp.player_id,'gross',lp.gross_amount,'commission',lp.commission,'net',lp.net_amount)) from public.ludo_payouts lp where lp.room_id=p_room),'[]'::jsonb));
end; $$;

create or replace function public.jl_ludo_my_status(p_token text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid:=public.jl_player_id(p_token); rid uuid;
begin perform public.jl_ludo_ensure_code(me); delete from public.ludo_waiting_queue where expires_at<=now(); select r.id into rid from public.ludo_room_players rp join public.ludo_rooms r on r.id=rp.room_id where rp.player_id=me and rp.status<>'left' and r.status in ('waiting','negotiating','funding','playing') order by r.created_at desc limit 1; return jsonb_build_object('identity',jsonb_build_object('player_id',me,'name',(select name from public.players where id=me),'code',public.jl_ludo_display_code(me),'house_number',(select house_number from public.ludo_player_codes where player_id=me),'balance',(select balance from public.players where id=me)),'active_room_id',rid,'queue',(select case when w.player_id is null then null else to_jsonb(w) end from public.ludo_waiting_queue w where w.player_id=me),'invites',public.jl_ludo_my_invites(p_token)); end; $$;

revoke execute on function public.jl_ludo_defaults() from public, anon, authenticated;
revoke execute on function public.jl_ludo_rules(jsonb,numeric) from public, anon, authenticated;
revoke execute on function public.jl_ludo_ensure_code(uuid) from public, anon, authenticated;
revoke execute on function public.jl_ludo_display_code(uuid) from public, anon, authenticated;
revoke execute on function public.jl_ludo_room_code() from public, anon, authenticated;
revoke execute on function public.jl_ludo_is_member(uuid,uuid) from public, anon, authenticated;
revoke execute on function public.jl_ludo_color_start(text) from public, anon, authenticated;
revoke execute on function public.jl_ludo_global_cell(text,integer) from public, anon, authenticated;
revoke execute on function public.jl_ludo_is_safe_cell(integer) from public, anon, authenticated;
revoke execute on function public.jl_ludo_event(uuid,uuid,text,jsonb) from public, anon, authenticated;
revoke execute on function public.jl_ludo_join_room_internal(uuid,uuid) from public, anon, authenticated;
revoke execute on function public.jl_ludo_refund_room(uuid,text) from public, anon, authenticated;
revoke execute on function public.jl_ludo_start_game(uuid) from public, anon, authenticated;
revoke execute on function public.jl_ludo_legal_moves_data(uuid,uuid,integer) from public, anon, authenticated;
revoke execute on function public.jl_ludo_check_finish(uuid) from public, anon, authenticated;
revoke execute on function public.jl_ludo_finish_room(uuid,uuid,integer) from public, anon, authenticated;
revoke execute on function public.jl_ludo_advance_turn(uuid,uuid,boolean) from public, anon, authenticated;
revoke execute on function public.jl_ludo_apply_capture_penalty(uuid,uuid) from public, anon, authenticated;
revoke execute on function public.jl_ludo_create_room(text,integer,numeric,text,boolean,jsonb) from public;
revoke execute on function public.jl_ludo_find_players(text,text) from public;
revoke execute on function public.jl_ludo_enter_queue(text,numeric,integer,text) from public;
revoke execute on function public.jl_ludo_leave_queue(text) from public;
revoke execute on function public.jl_ludo_waiting_players(text,uuid) from public;
revoke execute on function public.jl_ludo_invite(text,uuid,uuid) from public;
revoke execute on function public.jl_ludo_my_invites(text) from public;
revoke execute on function public.jl_ludo_accept_invite(text,uuid,boolean) from public;
revoke execute on function public.jl_ludo_join_public_room(text,text) from public;
revoke execute on function public.jl_ludo_update_rules(text,uuid,jsonb) from public;
revoke execute on function public.jl_ludo_accept_rules(text,uuid,boolean) from public;
revoke execute on function public.jl_ludo_commit_stake(text,uuid) from public;
revoke execute on function public.jl_ludo_roll(text,uuid) from public;
revoke execute on function public.jl_ludo_move(text,uuid,integer) from public;
revoke execute on function public.jl_ludo_reenter(text,uuid) from public;
revoke execute on function public.jl_ludo_process_timeouts(text,uuid) from public;
revoke execute on function public.jl_ludo_send_chat(text,uuid,text) from public;
revoke execute on function public.jl_ludo_signal_send(text,uuid,uuid,text,jsonb) from public;
revoke execute on function public.jl_ludo_signal_pull(text,uuid,bigint) from public;
revoke execute on function public.jl_ludo_cancel_or_leave(text,uuid) from public;
revoke execute on function public.jl_ludo_room_state(text,uuid) from public;
revoke execute on function public.jl_ludo_my_status(text) from public;

grant execute on function public.jl_ludo_create_room(text,integer,numeric,text,boolean,jsonb) to anon, authenticated;
grant execute on function public.jl_ludo_find_players(text,text) to anon, authenticated;
grant execute on function public.jl_ludo_enter_queue(text,numeric,integer,text) to anon, authenticated;
grant execute on function public.jl_ludo_leave_queue(text) to anon, authenticated;
grant execute on function public.jl_ludo_waiting_players(text,uuid) to anon, authenticated;
grant execute on function public.jl_ludo_invite(text,uuid,uuid) to anon, authenticated;
grant execute on function public.jl_ludo_my_invites(text) to anon, authenticated;
grant execute on function public.jl_ludo_accept_invite(text,uuid,boolean) to anon, authenticated;
grant execute on function public.jl_ludo_join_public_room(text,text) to anon, authenticated;
grant execute on function public.jl_ludo_update_rules(text,uuid,jsonb) to anon, authenticated;
grant execute on function public.jl_ludo_accept_rules(text,uuid,boolean) to anon, authenticated;
grant execute on function public.jl_ludo_commit_stake(text,uuid) to anon, authenticated;
grant execute on function public.jl_ludo_roll(text,uuid) to anon, authenticated;
grant execute on function public.jl_ludo_move(text,uuid,integer) to anon, authenticated;
grant execute on function public.jl_ludo_reenter(text,uuid) to anon, authenticated;
grant execute on function public.jl_ludo_process_timeouts(text,uuid) to anon, authenticated;
grant execute on function public.jl_ludo_send_chat(text,uuid,text) to anon, authenticated;
grant execute on function public.jl_ludo_signal_send(text,uuid,uuid,text,jsonb) to anon, authenticated;
grant execute on function public.jl_ludo_signal_pull(text,uuid,bigint) to anon, authenticated;
grant execute on function public.jl_ludo_cancel_or_leave(text,uuid) to anon, authenticated;
grant execute on function public.jl_ludo_room_state(text,uuid) to anon, authenticated;
grant execute on function public.jl_ludo_my_status(text) to anon, authenticated;

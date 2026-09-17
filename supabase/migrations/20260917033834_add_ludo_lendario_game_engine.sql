create or replace function public.jl_ludo_legal_moves_data(p_room uuid,p_player uuid,p_dice integer) returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.ludo_rooms%rowtype; rp public.ludo_room_players%rowtype; t record; ns int; cell int; exitok bool; caps jsonb; arr jsonb:='[]'::jsonb; blocked bool; i int; icell int;
begin
 select * into r from public.ludo_rooms where id=p_room; select * into rp from public.ludo_room_players where room_id=p_room and player_id=p_player; if r.id is null or rp.player_id is null then return '[]'::jsonb; end if;
 exitok := case r.rules->>'base_exit_rule' when 'one_or_six' then p_dice in (1,6) else p_dice=6 end;
 for t in select * from public.ludo_tokens where room_id=p_room and player_id=p_player order by token_no loop
   blocked:=false; caps:='[]'::jsonb; cell:=null;
   if t.steps=-1 then if not exitok then continue; end if; ns:=0; else ns:=t.steps+p_dice; if (r.rules->>'exact_finish')::boolean and ns>57 then continue; end if; if ns>57 then ns:=57; end if; if t.steps=57 then continue; end if; end if;
   if ns<=51 then
     cell:=public.jl_ludo_global_cell(rp.color,ns);
     if (r.rules->>'blockades')::boolean then
       if t.steps>=0 then
         for i in t.steps+1..ns loop
           if i>51 then exit; end if; icell:=public.jl_ludo_global_cell(rp.color,i);
           if exists(select 1 from (select ot.player_id,count(*) c from public.ludo_tokens ot join public.ludo_room_players op on op.room_id=ot.room_id and op.player_id=ot.player_id where ot.room_id=p_room and ot.steps between 0 and 51 and public.jl_ludo_global_cell(op.color,ot.steps)=icell and ot.player_id<>p_player and op.status in ('active','reentry','finished') group by ot.player_id having count(*)>=2) z) then blocked:=true; exit; end if;
         end loop;
       else
         if exists(select 1 from (select ot.player_id,count(*) c from public.ludo_tokens ot join public.ludo_room_players op on op.room_id=ot.room_id and op.player_id=ot.player_id where ot.room_id=p_room and ot.steps between 0 and 51 and public.jl_ludo_global_cell(op.color,ot.steps)=cell and ot.player_id<>p_player and op.status in ('active','reentry','finished') group by ot.player_id having count(*)>=2) z) then blocked:=true; end if;
       end if;
     end if;
     if blocked then continue; end if;
     if not ((r.rules->>'safe_cells')::boolean and public.jl_ludo_is_safe_cell(cell)) then
       select coalesce(jsonb_agg(jsonb_build_object('player_id',ot.player_id,'token_no',ot.token_no)),'[]'::jsonb) into caps from public.ludo_tokens ot join public.ludo_room_players op on op.room_id=ot.room_id and op.player_id=ot.player_id where ot.room_id=p_room and ot.player_id<>p_player and ot.steps between 0 and 51 and public.jl_ludo_global_cell(op.color,ot.steps)=cell and op.status in ('active','reentry','finished') and (r.mode='solo' or op.team is distinct from rp.team or (r.rules->>'partner_capture')::boolean);
     end if;
   end if;
   arr:=arr||jsonb_build_array(jsonb_build_object('token_no',t.token_no,'from_steps',t.steps,'to_steps',ns,'cell',cell,'captures',caps,'is_capture',jsonb_array_length(caps)>0,'finishes',ns=57));
 end loop; return arr;
end; $$;

create or replace function public.jl_ludo_check_finish(p_room uuid) returns boolean language plpgsql security definer set search_path = public as $$
declare r public.ludo_rooms%rowtype; p uuid; tm int; active_players int; active_teams int;
begin
 select * into r from public.ludo_rooms where id=p_room for update; if r.status<>'playing' then return false; end if;
 update public.ludo_room_players rp set status='finished' where rp.room_id=p_room and rp.status='active' and 4=(select count(*) from public.ludo_tokens t where t.room_id=p_room and t.player_id=rp.player_id and t.steps=57);
 if r.mode='solo' then
   select player_id into p from public.ludo_room_players where room_id=p_room and status='finished' order by seat limit 1; if p is not null then perform public.jl_ludo_finish_room(p_room,p,null); return true; end if;
   select count(*) into active_players from public.ludo_room_players where room_id=p_room and status in ('active','reentry'); if active_players=1 then select player_id into p from public.ludo_room_players where room_id=p_room and status in ('active','reentry') limit 1; perform public.jl_ludo_finish_room(p_room,p,null); return true; end if;
 else
   select team into tm from public.ludo_room_players where room_id=p_room group by team having bool_and(status='finished') and count(*)=2 limit 1; if tm is not null then perform public.jl_ludo_finish_room(p_room,null,tm); return true; end if;
   select count(distinct team) into active_teams from public.ludo_room_players where room_id=p_room and status in ('active','reentry','finished'); if active_teams=1 then select team into tm from public.ludo_room_players where room_id=p_room and status in ('active','reentry','finished') limit 1; perform public.jl_ludo_finish_room(p_room,null,tm); return true; end if;
 end if; return false;
end; $$;

create or replace function public.jl_ludo_finish_room(p_room uuid,p_winner uuid,p_team integer) returns void language plpgsql security definer set search_path = public as $$
declare r public.ludo_rooms%rowtype; gross numeric; comm numeric; net numeric; x record; total_comm numeric:=0;
begin
 select * into r from public.ludo_rooms where id=p_room for update; if r.status='finished' then return; end if;
 if r.mode='solo' then
   if p_winner is null then raise exception 'Vencedor inválido.'; end if; gross:=round(r.pot,2); comm:=least(gross,greatest(1,round(gross*0.01,2))); net:=gross-comm;
   update public.players set balance=balance+net,updated_at=now() where id=p_winner;
   insert into public.ludo_payouts(room_id,player_id,gross_amount,commission,net_amount) values(p_room,p_winner,gross,comm,net) on conflict do nothing;
   insert into public.transactions(player_id,kind,amount,status,reference_id,note) values(p_winner,'ludo_payout',net,'completed',p_room,'Prémio Ludo líquido; comissão '||comm||' MZN'); total_comm:=comm;
   update public.ludo_room_players set status=case when player_id=p_winner then 'finished' else status end where room_id=p_room;
 else
   if p_team not in (1,2) then raise exception 'Equipa vencedora inválida.'; end if; gross:=round(r.pot/2,2);
   for x in select player_id from public.ludo_room_players where room_id=p_room and team=p_team order by seat loop
     comm:=least(gross,greatest(1,round(gross*0.01,2))); net:=gross-comm; update public.players set balance=balance+net,updated_at=now() where id=x.player_id;
     insert into public.ludo_payouts(room_id,player_id,gross_amount,commission,net_amount) values(p_room,x.player_id,gross,comm,net) on conflict do nothing;
     insert into public.transactions(player_id,kind,amount,status,reference_id,note) values(x.player_id,'ludo_payout',net,'completed',p_room,'Prémio Ludo parceiros líquido; comissão individual '||comm||' MZN'); total_comm:=total_comm+comm;
   end loop;
 end if;
 update public.ludo_rooms set status='finished',winner_player_id=p_winner,winner_team=p_team,commission_total=total_comm,turn_phase=null,dice_result=null,action_deadline=null,finished_at=now(),updated_at=now() where id=p_room;
 perform public.jl_ludo_event(p_room,p_winner,'game_finished',jsonb_build_object('winner_player_id',p_winner,'winner_team',p_team,'pot',r.pot,'commission_total',total_comm));
end; $$;

create or replace function public.jl_ludo_advance_turn(p_room uuid,p_current uuid,p_extra boolean default false) returns void language plpgsql security definer set search_path = public as $$
declare r public.ludo_rooms%rowtype; curseat int; nxt uuid; secs int;
begin
 select * into r from public.ludo_rooms where id=p_room for update; if r.status<>'playing' then return; end if; if public.jl_ludo_check_finish(p_room) then return; end if; secs:=(r.rules->>'turn_seconds')::int;
 if p_extra and exists(select 1 from public.ludo_room_players where room_id=p_room and player_id=p_current and status='active') then nxt:=p_current;
 else select seat into curseat from public.ludo_room_players where room_id=p_room and player_id=p_current; select player_id into nxt from public.ludo_room_players where room_id=p_room and status='active' and seat>coalesce(curseat,0) order by seat limit 1; if nxt is null then select player_id into nxt from public.ludo_room_players where room_id=p_room and status='active' order by seat limit 1; end if; end if;
 if nxt is null then perform public.jl_ludo_check_finish(p_room); return; end if; if nxt<>p_current then update public.ludo_room_players set consecutive_sixes=0 where room_id=p_room and player_id=p_current; end if;
 update public.ludo_rooms set current_player_id=nxt,turn_phase='roll',dice_result=null,action_deadline=now()+make_interval(secs=>secs),updated_at=now() where id=p_room; perform public.jl_ludo_event(p_room,nxt,'turn_started',jsonb_build_object('deadline',now()+make_interval(secs=>secs)));
end; $$;

create or replace function public.jl_ludo_roll(p_token text,p_room uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid:=public.jl_player_id(p_token); r public.ludo_rooms%rowtype; d int; moves jsonb; rp public.ludo_room_players%rowtype; move_secs int;
begin
 perform public.jl_ludo_process_timeouts(p_token,p_room); select * into r from public.ludo_rooms where id=p_room for update;
 if r.status<>'playing' or r.current_player_id<>me or r.turn_phase<>'roll' then raise exception 'Não é hora de lançar o dado.'; end if; if r.action_deadline<=now() then raise exception 'Tempo da jogada expirou.'; end if;
 select * into rp from public.ludo_room_players where room_id=p_room and player_id=me for update; d:=public.jl_random_index(6);
 if d=6 then update public.ludo_room_players set consecutive_sixes=consecutive_sixes+1 where room_id=p_room and player_id=me returning * into rp; else update public.ludo_room_players set consecutive_sixes=0 where room_id=p_room and player_id=me returning * into rp; end if;
 perform public.jl_ludo_event(p_room,me,'dice_rolled',jsonb_build_object('dice',d));
 if d=6 and (r.rules->>'three_sixes_penalty')::boolean and rp.consecutive_sixes>=3 then perform public.jl_ludo_event(p_room,me,'three_sixes_penalty',jsonb_build_object('dice',d)); perform public.jl_ludo_advance_turn(p_room,me,false); return public.jl_ludo_room_state(p_token,p_room); end if;
 moves:=public.jl_ludo_legal_moves_data(p_room,me,d);
 if jsonb_array_length(moves)=0 then perform public.jl_ludo_event(p_room,me,'no_legal_move',jsonb_build_object('dice',d)); perform public.jl_ludo_advance_turn(p_room,me,d=6 and (r.rules->>'six_extra_turn')::boolean);
 else move_secs:=(r.rules->>'move_seconds')::int; update public.ludo_rooms set dice_result=d,turn_phase='move',action_deadline=now()+make_interval(secs=>move_secs),updated_at=now() where id=p_room; end if;
 return public.jl_ludo_room_state(p_token,p_room);
end; $$;

create or replace function public.jl_ludo_apply_capture_penalty(p_room uuid,p_player uuid) returns text language plpgsql security definer set search_path = public as $$
declare r public.ludo_rooms%rowtype; pen text; secs int;
begin
 select * into r from public.ludo_rooms where id=p_room for update; pen:=r.rules->>'capture_penalty';
 if pen='lose_turn' then perform public.jl_ludo_event(p_room,p_player,'capture_required_missed',jsonb_build_object('penalty','lose_turn')); perform public.jl_ludo_advance_turn(p_room,p_player,false);
 elsif pen='eliminate' or not (r.rules->>'reentry_allowed')::boolean then update public.ludo_room_players set status='eliminated',reentry_deadline=null where room_id=p_room and player_id=p_player; perform public.jl_ludo_event(p_room,p_player,'player_eliminated',jsonb_build_object('reason','capture_required')); perform public.jl_ludo_advance_turn(p_room,p_player,false);
 else secs:=(r.rules->>'reentry_seconds')::int; update public.ludo_room_players set status='reentry',reentry_deadline=now()+make_interval(secs=>secs) where room_id=p_room and player_id=p_player; perform public.jl_ludo_event(p_room,p_player,'reentry_required',jsonb_build_object('reason','capture_required','amount',(r.rules->>'reentry_amount')::numeric,'deadline',now()+make_interval(secs=>secs))); perform public.jl_ludo_advance_turn(p_room,p_player,false); end if; return pen;
end; $$;

create or replace function public.jl_ludo_move(p_token text,p_room uuid,p_token_no integer) returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid:=public.jl_player_id(p_token); r public.ludo_rooms%rowtype; moves jsonb; m jsonb; cap_exists bool; selected_capture bool; ns int; c jsonb; target uuid; target_no int; extra bool:=false;
begin
 perform public.jl_ludo_process_timeouts(p_token,p_room); select * into r from public.ludo_rooms where id=p_room for update;
 if r.status<>'playing' or r.current_player_id<>me or r.turn_phase<>'move' or r.dice_result is null then raise exception 'Não há peça aguardando movimento.'; end if; if r.action_deadline<=now() then raise exception 'Tempo para escolher a peça expirou.'; end if;
 moves:=public.jl_ludo_legal_moves_data(p_room,me,r.dice_result); select value into m from jsonb_array_elements(moves) where (value->>'token_no')::int=p_token_no limit 1; if m is null then raise exception 'Movimento inválido para este dado.'; end if;
 select exists(select 1 from jsonb_array_elements(moves) z where (z->>'is_capture')::boolean) into cap_exists; selected_capture:=(m->>'is_capture')::boolean;
 if (r.rules->>'capture_required')::boolean and cap_exists and not selected_capture then perform public.jl_ludo_apply_capture_penalty(p_room,me); return public.jl_ludo_room_state(p_token,p_room); end if;
 ns:=(m->>'to_steps')::int; update public.ludo_tokens set steps=ns,updated_at=now() where room_id=p_room and player_id=me and token_no=p_token_no;
 for c in select value from jsonb_array_elements(m->'captures') loop target:=(c->>'player_id')::uuid; target_no:=(c->>'token_no')::int; update public.ludo_tokens set steps=-1,updated_at=now() where room_id=p_room and player_id=target and token_no=target_no; perform public.jl_ludo_event(p_room,me,'token_captured',jsonb_build_object('victim',target,'victim_token',target_no,'by_token',p_token_no)); end loop;
 perform public.jl_ludo_event(p_room,me,'token_moved',jsonb_build_object('token_no',p_token_no,'dice',r.dice_result,'from_steps',(m->>'from_steps')::int,'to_steps',ns,'capture',selected_capture));
 if public.jl_ludo_check_finish(p_room) then return public.jl_ludo_room_state(p_token,p_room); end if; extra := (r.dice_result=6 and (r.rules->>'six_extra_turn')::boolean) or (selected_capture and (r.rules->>'capture_extra_turn')::boolean); perform public.jl_ludo_advance_turn(p_room,me,extra); return public.jl_ludo_room_state(p_token,p_room);
end; $$;

create or replace function public.jl_ludo_reenter(p_token text,p_room uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid:=public.jl_player_id(p_token); r public.ludo_rooms%rowtype; rp public.ludo_room_players%rowtype; pl public.players%rowtype; amt numeric;
begin
 select * into r from public.ludo_rooms where id=p_room for update; select * into rp from public.ludo_room_players where room_id=p_room and player_id=me for update;
 if r.status<>'playing' or rp.status<>'reentry' or rp.reentry_deadline is null or rp.reentry_deadline<=now() then raise exception 'Reentrada indisponível ou expirada.'; end if; amt:=(r.rules->>'reentry_amount')::numeric;
 select * into pl from public.players where id=me for update; if pl.balance<amt then raise exception 'Saldo insuficiente para reentrar.'; end if;
 update public.players set balance=balance-amt,updated_at=now() where id=me; update public.ludo_rooms set pot=pot+amt,updated_at=now() where id=p_room; update public.ludo_room_players set status='active',reentry_deadline=null where room_id=p_room and player_id=me;
 insert into public.transactions(player_id,kind,amount,status,reference_id,note) values(me,'ludo_reentry',-amt,'completed',p_room,'Reentrada no Ludo '||r.code); perform public.jl_ludo_event(p_room,me,'player_reentered',jsonb_build_object('amount',amt)); return public.jl_ludo_room_state(p_token,p_room);
end; $$;

create or replace function public.jl_ludo_process_timeouts(p_token text,p_room uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid:=public.jl_player_id(p_token); r public.ludo_rooms%rowtype; cur uuid; limitn int;
begin
 if not public.jl_ludo_is_member(p_room,me) then raise exception 'Você não pertence a esta sala.'; end if; select * into r from public.ludo_rooms where id=p_room for update; update public.ludo_invitations set status='expired' where room_id=p_room and status='pending' and expires_at<=now();
 if r.status='negotiating' and r.action_deadline is not null and r.action_deadline<=now() then delete from public.ludo_room_players where room_id=p_room and player_id<>r.host_id and coalesce(accepted_rules_version,0)<>r.rules_version; update public.ludo_rooms set status='waiting',action_deadline=null,updated_at=now() where id=p_room; perform public.jl_ludo_event(p_room,null,'negotiation_timeout','{}'::jsonb);
 elsif r.status='funding' and r.action_deadline is not null and r.action_deadline<=now() then delete from public.ludo_room_players where room_id=p_room and player_id<>r.host_id and not stake_paid; perform public.jl_ludo_refund_room(p_room,'Reembolso: tempo de confirmação da sala expirou'); update public.ludo_room_players set accepted_rules_version=case when player_id=r.host_id then r.rules_version else null end where room_id=p_room; update public.ludo_rooms set status='waiting',action_deadline=null,updated_at=now() where id=p_room; perform public.jl_ludo_event(p_room,null,'funding_timeout','{}'::jsonb);
 elsif r.status='playing' then
   update public.ludo_room_players set status='eliminated',reentry_deadline=null where room_id=p_room and status='reentry' and reentry_deadline<=now(); if public.jl_ludo_check_finish(p_room) then return public.jl_ludo_room_state(p_token,p_room); end if;
   if r.action_deadline is not null and r.action_deadline<=now() and r.current_player_id is not null then cur:=r.current_player_id; limitn:=(r.rules->>'idle_strikes_limit')::int; update public.ludo_room_players set timeout_strikes=timeout_strikes+1 where room_id=p_room and player_id=cur; perform public.jl_ludo_event(p_room,cur,'action_timeout',jsonb_build_object('phase',r.turn_phase)); if (select timeout_strikes from public.ludo_room_players where room_id=p_room and player_id=cur)>=limitn then update public.ludo_room_players set status='eliminated' where room_id=p_room and player_id=cur; perform public.jl_ludo_event(p_room,cur,'player_eliminated',jsonb_build_object('reason','timeouts')); end if; perform public.jl_ludo_advance_turn(p_room,cur,false); end if;
 end if; return public.jl_ludo_room_state(p_token,p_room);
end; $$;

create or replace function public.jl_ludo_create_room(
  p_token text,p_player_count integer,p_bet_amount numeric,p_mode text default 'solo',p_is_public boolean default false,p_rules jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_player uuid := public.jl_player_id(p_token); v_room public.ludo_rooms%rowtype; v_rules jsonb;
begin
 if p_player_count not between 2 and 4 then raise exception 'Ludo aceita 2, 3 ou 4 jogadores.'; end if;
 if p_mode not in ('solo','partners') then raise exception 'Modo inválido.'; end if;
 if p_mode='partners' and p_player_count<>4 then raise exception 'Modo parceiros requer 4 jogadores.'; end if;
 if p_bet_amount is null or p_bet_amount < 1 then raise exception 'A aposta deve ser maior que zero.'; end if;
 if exists(select 1 from public.ludo_room_players rp join public.ludo_rooms r on r.id=rp.room_id where rp.player_id=v_player and rp.status<>'left' and r.status in ('waiting','negotiating','funding','playing')) then raise exception 'Você já participa de uma sala de Ludo ativa.'; end if;
 perform public.jl_ludo_ensure_code(v_player); v_rules := public.jl_ludo_rules(p_rules,p_bet_amount);
 insert into public.ludo_rooms(code,host_id,player_count,mode,bet_amount,is_public,rules,status,action_deadline)
 values(public.jl_ludo_room_code(),v_player,p_player_count,p_mode,round(p_bet_amount,2),p_is_public,v_rules,'waiting',now()+make_interval(secs=>(v_rules->>'rules_response_seconds')::integer)) returning * into v_room;
 insert into public.ludo_room_players(room_id,player_id,seat,color,team,accepted_rules_version) values(v_room.id,v_player,1,'red',case when p_mode='partners' then 1 else null end,v_room.rules_version);
 perform public.jl_ludo_event(v_room.id,v_player,'room_created',jsonb_build_object('code',v_room.code,'bet',v_room.bet_amount,'players',v_room.player_count,'mode',v_room.mode));
 return public.jl_ludo_room_state(p_token,v_room.id);
end; $$;

create or replace function public.jl_ludo_find_players(p_token text, p_query text default '') returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := public.jl_player_id(p_token); q text := trim(coalesce(p_query,''));
begin
 perform public.jl_ludo_ensure_code(me);
 return coalesce((select jsonb_agg(jsonb_build_object('player_id',p.id,'name',p.name,'code',public.jl_ludo_display_code(p.id),'house_number',c.house_number,'waiting',exists(select 1 from public.ludo_waiting_queue w where w.player_id=p.id and w.expires_at>now())) order by p.name,c.house_number)
 from (select p0.* from public.players p0 where p0.id<>me and not p0.blocked and (q='' or p0.name ilike '%'||q||'%') order by p0.name limit 30) p
 join public.ludo_player_codes c on c.player_id=p.id),'[]'::jsonb);
end; $$;

create or replace function public.jl_ludo_enter_queue(p_token text,p_bet_amount numeric,p_player_count integer,p_mode text default 'solo') returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := public.jl_player_id(p_token);
begin
 if p_player_count not between 2 and 4 then raise exception 'Quantidade de jogadores inválida.'; end if;
 if p_mode not in ('solo','partners') or (p_mode='partners' and p_player_count<>4) then raise exception 'Modo inválido.'; end if;
 if p_bet_amount<1 then raise exception 'Aposta inválida.'; end if;
 if exists(select 1 from public.ludo_room_players rp join public.ludo_rooms r on r.id=rp.room_id where rp.player_id=me and rp.status<>'left' and r.status in ('waiting','negotiating','funding','playing')) then raise exception 'Você já participa de uma sala ativa.'; end if;
 perform public.jl_ludo_ensure_code(me);
 insert into public.ludo_waiting_queue(player_id,bet_amount,player_count,mode,joined_at,expires_at) values(me,round(p_bet_amount,2),p_player_count,p_mode,now(),now()+interval '15 minutes') on conflict(player_id) do update set bet_amount=excluded.bet_amount,player_count=excluded.player_count,mode=excluded.mode,joined_at=now(),expires_at=excluded.expires_at;
 return jsonb_build_object('ok',true,'code',public.jl_ludo_display_code(me),'expires_at',now()+interval '15 minutes');
end; $$;
create or replace function public.jl_ludo_leave_queue(p_token text) returns jsonb language plpgsql security definer set search_path = public as $$ declare me uuid := public.jl_player_id(p_token); begin delete from public.ludo_waiting_queue where player_id=me; return jsonb_build_object('ok',true); end; $$;

create or replace function public.jl_ludo_waiting_players(p_token text,p_room uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := public.jl_player_id(p_token); r public.ludo_rooms%rowtype;
begin
 select * into r from public.ludo_rooms where id=p_room; if r.id is null or not public.jl_ludo_is_member(p_room,me) then raise exception 'Sala não encontrada.'; end if;
 delete from public.ludo_waiting_queue where expires_at<=now();
 return coalesce((select jsonb_agg(jsonb_build_object('player_id',w.player_id,'name',p.name,'code',public.jl_ludo_display_code(w.player_id),'joined_at',w.joined_at) order by w.joined_at) from public.ludo_waiting_queue w join public.players p on p.id=w.player_id where w.player_id<>me and w.player_count=r.player_count and w.mode=r.mode and w.bet_amount=r.bet_amount and not exists(select 1 from public.ludo_room_players rp where rp.room_id=p_room and rp.player_id=w.player_id and rp.status<>'left')),'[]'::jsonb);
end; $$;

create or replace function public.jl_ludo_invite(p_token text,p_room uuid,p_target_player uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := public.jl_player_id(p_token); r public.ludo_rooms%rowtype; secs int; inv uuid;
begin
 select * into r from public.ludo_rooms where id=p_room for update;
 if r.id is null or r.host_id<>me then raise exception 'Apenas o anfitrião pode convidar.'; end if;
 if r.status not in ('waiting','negotiating') then raise exception 'A sala não aceita novos jogadores neste momento.'; end if;
 if p_target_player=me or not exists(select 1 from public.players where id=p_target_player and not blocked) then raise exception 'Jogador inválido.'; end if;
 if (select count(*) from public.ludo_room_players where room_id=p_room and status<>'left') >= r.player_count then raise exception 'Sala cheia.'; end if;
 secs := (r.rules->>'invite_seconds')::int; update public.ludo_invitations set status='cancelled' where room_id=p_room and target_player_id=p_target_player and status='pending';
 insert into public.ludo_invitations(room_id,invited_by,target_player_id,expires_at) values(p_room,me,p_target_player,now()+make_interval(secs=>secs)) returning id into inv;
 perform public.jl_ludo_event(p_room,me,'invite_sent',jsonb_build_object('target',p_target_player,'expires_in',secs)); return jsonb_build_object('ok',true,'invitation_id',inv,'expires_at',now()+make_interval(secs=>secs));
end; $$;

create or replace function public.jl_ludo_my_invites(p_token text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := public.jl_player_id(p_token);
begin
 update public.ludo_invitations set status='expired' where target_player_id=me and status='pending' and expires_at<=now();
 return coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'room_id',i.room_id,'room_code',r.code,'host',p.name,'host_code',public.jl_ludo_display_code(r.host_id),'bet_amount',r.bet_amount,'player_count',r.player_count,'mode',r.mode,'expires_at',i.expires_at) order by i.created_at desc) from public.ludo_invitations i join public.ludo_rooms r on r.id=i.room_id join public.players p on p.id=r.host_id where i.target_player_id=me and i.status='pending' and i.expires_at>now()),'[]'::jsonb);
end; $$;

create or replace function public.jl_ludo_join_room_internal(p_room uuid,p_player uuid) returns void language plpgsql security definer set search_path = public as $$
declare r public.ludo_rooms%rowtype; s int; col text; tm int;
begin
 select * into r from public.ludo_rooms where id=p_room for update; if r.id is null or r.status not in ('waiting','negotiating') then raise exception 'Sala indisponível.'; end if;
 if exists(select 1 from public.ludo_room_players where room_id=p_room and player_id=p_player and status<>'left') then return; end if;
 if exists(select 1 from public.ludo_room_players rp join public.ludo_rooms rr on rr.id=rp.room_id where rp.player_id=p_player and rp.status<>'left' and rr.status in ('waiting','negotiating','funding','playing') and rr.id<>p_room) then raise exception 'O jogador já participa de outra sala ativa.'; end if;
 if (select count(*) from public.ludo_room_players where room_id=p_room and status<>'left') >= r.player_count then raise exception 'Sala cheia.'; end if;
 select x into s from generate_series(1,r.player_count) x where not exists(select 1 from public.ludo_room_players where room_id=p_room and seat=x and status<>'left') order by x limit 1;
 col := case s when 1 then 'red' when 2 then case when r.player_count=2 then 'yellow' else 'green' end when 3 then 'yellow' else 'blue' end;
 if r.player_count=2 and s=2 then col:='yellow'; end if; tm := case when r.mode='partners' then case when s in (1,3) then 1 else 2 end else null end;
 insert into public.ludo_room_players(room_id,player_id,seat,color,team,status) values(p_room,p_player,s,col,tm,'active'); perform public.jl_ludo_ensure_code(p_player);
 update public.ludo_rooms set status='negotiating', action_deadline=now()+make_interval(secs=>(rules->>'rules_response_seconds')::int),updated_at=now() where id=p_room;
 perform public.jl_ludo_event(p_room,p_player,'player_joined',jsonb_build_object('seat',s,'color',col,'team',tm));
end; $$;

create or replace function public.jl_ludo_accept_invite(p_token text,p_invitation uuid,p_accept boolean default true) returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid:=public.jl_player_id(p_token); i public.ludo_invitations%rowtype;
begin
 select * into i from public.ludo_invitations where id=p_invitation and target_player_id=me for update; if i.id is null then raise exception 'Convite não encontrado.'; end if;
 if i.status<>'pending' or i.expires_at<=now() then update public.ludo_invitations set status='expired' where id=i.id; raise exception 'Convite expirado.'; end if;
 if not p_accept then update public.ludo_invitations set status='declined' where id=i.id; return jsonb_build_object('ok',true,'accepted',false); end if;
 perform public.jl_ludo_join_room_internal(i.room_id,me); update public.ludo_invitations set status='accepted' where id=i.id; delete from public.ludo_waiting_queue where player_id=me; return public.jl_ludo_room_state(p_token,i.room_id);
end; $$;

create or replace function public.jl_ludo_join_public_room(p_token text,p_code text) returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid:=public.jl_player_id(p_token); r uuid;
begin select id into r from public.ludo_rooms where upper(code)=upper(trim(p_code)) and is_public and status in ('waiting','negotiating'); if r is null then raise exception 'Sala pública não encontrada.'; end if; perform public.jl_ludo_join_room_internal(r,me); delete from public.ludo_waiting_queue where player_id=me; return public.jl_ludo_room_state(p_token,r); end; $$;

create or replace function public.jl_ludo_update_rules(p_token text,p_room uuid,p_rules jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid:=public.jl_player_id(p_token); r public.ludo_rooms%rowtype; nr jsonb;
begin
 select * into r from public.ludo_rooms where id=p_room for update; if r.id is null or r.host_id<>me then raise exception 'Apenas o anfitrião pode alterar as regras.'; end if; if r.status not in ('waiting','negotiating') then raise exception 'As regras já estão bloqueadas para esta partida.'; end if;
 nr := public.jl_ludo_rules(p_rules,r.bet_amount); update public.ludo_rooms set rules=nr,rules_version=rules_version+1,status='negotiating',action_deadline=now()+make_interval(secs=>(nr->>'rules_response_seconds')::int),updated_at=now() where id=p_room returning * into r;
 update public.ludo_room_players set accepted_rules_version=null where room_id=p_room and status<>'left'; update public.ludo_room_players set accepted_rules_version=r.rules_version where room_id=p_room and player_id=me;
 perform public.jl_ludo_event(p_room,me,'rules_changed',jsonb_build_object('version',r.rules_version,'rules',nr)); return public.jl_ludo_room_state(p_token,p_room);
end; $$;

create or replace function public.jl_ludo_accept_rules(p_token text,p_room uuid,p_accept boolean) returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid:=public.jl_player_id(p_token); r public.ludo_rooms%rowtype; c int; a int;
begin
 select * into r from public.ludo_rooms where id=p_room for update; if r.id is null or r.status not in ('waiting','negotiating') or not public.jl_ludo_is_member(p_room,me) then raise exception 'Sala indisponível.'; end if;
 if not p_accept then update public.ludo_room_players set accepted_rules_version=null where room_id=p_room and player_id=me; perform public.jl_ludo_event(p_room,me,'rules_declined',jsonb_build_object('version',r.rules_version)); return public.jl_ludo_room_state(p_token,p_room); end if;
 update public.ludo_room_players set accepted_rules_version=r.rules_version where room_id=p_room and player_id=me and status<>'left'; select count(*),count(*) filter(where accepted_rules_version=r.rules_version) into c,a from public.ludo_room_players where room_id=p_room and status<>'left';
 if c=r.player_count and a=c then update public.ludo_rooms set status='funding',action_deadline=now()+make_interval(secs=>(rules->>'stake_seconds')::int),updated_at=now() where id=p_room; perform public.jl_ludo_event(p_room,me,'rules_unanimous',jsonb_build_object('version',r.rules_version)); end if; return public.jl_ludo_room_state(p_token,p_room);
end; $$;

create or replace function public.jl_ludo_refund_room(p_room uuid,p_note text default 'Reembolso Ludo') returns void language plpgsql security definer set search_path = public as $$
declare x record;
begin for x in select * from public.ludo_room_players where room_id=p_room and stake_paid loop update public.players set balance=balance+x.stake_amount,updated_at=now() where id=x.player_id; insert into public.transactions(player_id,kind,amount,status,reference_id,note) values(x.player_id,'ludo_refund',x.stake_amount,'completed',p_room,p_note); end loop; update public.ludo_room_players set stake_paid=false,stake_amount=0 where room_id=p_room; update public.ludo_rooms set pot=0,updated_at=now() where id=p_room; end; $$;

create or replace function public.jl_ludo_start_game(p_room uuid) returns void language plpgsql security definer set search_path = public as $$
declare r public.ludo_rooms%rowtype; firstp uuid; secs int; x record;
begin
 select * into r from public.ludo_rooms where id=p_room for update; if r.status<>'funding' then raise exception 'Sala não está pronta para iniciar.'; end if;
 if (select count(*) from public.ludo_room_players where room_id=p_room and status<>'left')<>r.player_count then raise exception 'Faltam jogadores.'; end if;
 if exists(select 1 from public.ludo_room_players where room_id=p_room and (not stake_paid or accepted_rules_version<>r.rules_version) and status<>'left') then raise exception 'Nem todos confirmaram regras e aposta.'; end if;
 for x in select player_id from public.ludo_room_players where room_id=p_room and status<>'left' loop insert into public.ludo_tokens(room_id,player_id,token_no) select p_room,x.player_id,n from generate_series(1,4)n on conflict do nothing; end loop;
 select player_id into firstp from public.ludo_room_players where room_id=p_room and status='active' order by seat limit 1; secs := (r.rules->>'turn_seconds')::int;
 update public.ludo_rooms set status='playing',current_player_id=firstp,turn_phase='roll',dice_result=null,action_deadline=now()+make_interval(secs=>secs),started_at=now(),updated_at=now() where id=p_room; perform public.jl_ludo_event(p_room,firstp,'game_started',jsonb_build_object('first_player',firstp,'deadline',now()+make_interval(secs=>secs)));
end; $$;

create or replace function public.jl_ludo_commit_stake(p_token text,p_room uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid:=public.jl_player_id(p_token); r public.ludo_rooms%rowtype; pl public.players%rowtype; rp public.ludo_room_players%rowtype;
begin
 select * into r from public.ludo_rooms where id=p_room for update; if r.id is null or r.status<>'funding' then raise exception 'A sala ainda não está na fase de aposta.'; end if; if r.action_deadline<=now() then raise exception 'Tempo para confirmar a aposta expirou.'; end if;
 select * into rp from public.ludo_room_players where room_id=p_room and player_id=me and status<>'left' for update; if rp.player_id is null or rp.accepted_rules_version<>r.rules_version then raise exception 'Aceite primeiro as regras atuais.'; end if; if rp.stake_paid then return public.jl_ludo_room_state(p_token,p_room); end if;
 select * into pl from public.players where id=me for update; if pl.blocked then raise exception 'Conta bloqueada.'; end if; if pl.balance<r.bet_amount then raise exception 'Saldo insuficiente para a aposta desta sala.'; end if;
 update public.players set balance=balance-r.bet_amount,updated_at=now() where id=me; update public.ludo_room_players set stake_paid=true,stake_amount=r.bet_amount where room_id=p_room and player_id=me; update public.ludo_rooms set pot=pot+r.bet_amount,updated_at=now() where id=p_room;
 insert into public.transactions(player_id,kind,amount,status,reference_id,note) values(me,'ludo_stake',-r.bet_amount,'completed',p_room,'Aposta Ludo '||r.code); perform public.jl_ludo_event(p_room,me,'stake_committed',jsonb_build_object('amount',r.bet_amount));
 if not exists(select 1 from public.ludo_room_players where room_id=p_room and status<>'left' and not stake_paid) then perform public.jl_ludo_start_game(p_room); end if; return public.jl_ludo_room_state(p_token,p_room);
end; $$;

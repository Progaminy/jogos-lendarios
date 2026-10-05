create or replace function public.jl_ludo_create_free_room(
  p_token text,p_player_count integer,p_mode text default 'solo',p_is_public boolean default false,p_rules jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid:=public.jl_player_id(p_token); r public.ludo_rooms%rowtype; ruleset jsonb; pawn_text text:=coalesce(p_rules->>'pawn_count','4'); pawn_count integer;
begin
  perform public.jl_free_access_require(me);
  if p_player_count not between 2 and 4 then raise exception 'Ludo aceita 2, 3 ou 4 jogadores.'; end if;
  if p_mode not in ('solo','partners') then raise exception 'Modo inválido.'; end if;
  if p_mode='partners' and p_player_count<>4 then raise exception 'Modo parceiros requer 4 jogadores.'; end if;
  if pawn_text !~ '^[1-4]$' then raise exception 'Quantidade de peões inválida.'; end if;
  pawn_count:=pawn_text::integer;
  if exists(select 1 from public.ludo_room_players rp join public.ludo_rooms x on x.id=rp.room_id where rp.player_id=me and rp.status<>'left' and x.status in ('waiting','negotiating','funding','playing')) then raise exception 'Você já participa de uma sala de Ludo ativa.'; end if;
  perform public.jl_ludo_ensure_code(me);
  ruleset:=public.jl_ludo_rules(coalesce(p_rules,'{}'::jsonb)-'pawn_count',10);
  ruleset:=jsonb_set(ruleset,'{capture_penalty}','"lose_turn"'::jsonb,true);
  ruleset:=jsonb_set(ruleset,'{reentry_allowed}','false'::jsonb,true);
  insert into public.ludo_rooms(code,host_id,player_count,pawn_count,mode,bet_amount,pot,is_public,rules,status,action_deadline,play_mode)
  values(public.jl_ludo_room_code(),me,p_player_count,pawn_count,p_mode,0,0,coalesce(p_is_public,false),ruleset,'waiting',null,'free') returning * into r;
  insert into public.ludo_room_players(room_id,player_id,seat,color,team,accepted_rules_version,stake_paid,stake_amount)
  values(r.id,me,1,'red',case when p_mode='partners' then 1 else null end,r.rules_version,true,0);
  perform public.jl_ludo_event(r.id,me,'room_created',jsonb_build_object('code',r.code,'free',true,'players',r.player_count,'pawns',r.pawn_count,'mode',r.mode));
  return public.jl_ludo_room_state(p_token,r.id);
end; $$;

create or replace function public.jl_ludo_create_free_from_board_invite(p_token text,p_board_invite uuid,p_rules jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid:=public.jl_player_id(p_token); inv public.board_invitations%rowtype; other uuid; created jsonb; rid uuid;
begin
  perform public.jl_free_access_require(me);
  select * into inv from public.board_invitations where id=p_board_invite for update;
  if inv.id is null or inv.status<>'accepted' or inv.selected_game<>'ludo' or (inv.sender_id<>me and inv.target_id<>me) then raise exception 'Convite global de Ludo inválido.'; end if;
  other:=case when inv.sender_id=me then inv.target_id else inv.sender_id end;
  perform public.jl_free_access_require(other);
  created:=public.jl_ludo_create_free_room(p_token,2,'solo',false,coalesce(p_rules,'{}'::jsonb));
  rid:=(created->'room'->>'id')::uuid;
  perform public.jl_ludo_invite(p_token,rid,other);
  update public.board_invitations set status='consumed',consumed_at=now() where id=p_board_invite;
  perform public.jl_ludo_event(rid,me,'board_invite_attached',jsonb_build_object('board_invite',p_board_invite,'opponent',other,'free',true));
  return public.jl_ludo_room_state(p_token,rid);
end; $$;

create or replace function public.jl_ludo_free_public_challenges(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid:=public.jl_player_id(p_token);
begin
  perform public.jl_free_access_require(me);
  return coalesce((select jsonb_agg(jsonb_build_object('room_id',r.id,'code',r.code,'host_id',r.host_id,'host_name',p.name,'host_code',public.jl_ludo_display_code(r.host_id),'player_count',r.player_count,'joined_count',x.joined_count,'open_slots',greatest(0,r.player_count-x.joined_count),'mode',r.mode,'bet_amount',0,'play_mode','free','status',r.status,'play_location',coalesce(r.rules->>'play_location','online'),'dice_count',coalesce((r.rules->>'dice_count')::integer,1),'created_at',r.created_at) order by r.updated_at desc)
    from public.ludo_rooms r join public.players p on p.id=r.host_id
    cross join lateral (select count(*)::integer joined_count from public.ludo_room_players rp where rp.room_id=r.id and rp.status<>'left') x
    where r.play_mode='free' and r.is_public and r.status in ('waiting','negotiating') and r.host_id<>me and x.joined_count<r.player_count
      and exists(select 1 from public.player_sessions ps where ps.player_id=r.host_id and ps.expires_at>now() and ps.last_seen_at>=now()-interval '30 seconds')
      and not exists(select 1 from public.ludo_room_players mine where mine.room_id=r.id and mine.player_id=me and mine.status<>'left')),'[]'::jsonb);
end; $$;

create or replace function public.jl_ludo_join_free_public_room(p_token text,p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid:=public.jl_player_id(p_token); rid uuid;
begin
  perform public.jl_free_access_require(me);
  select r.id into rid from public.ludo_rooms r where upper(r.code)=upper(trim(p_code)) and r.play_mode='free' and r.is_public and r.status in ('waiting','negotiating') and exists(select 1 from public.player_sessions ps where ps.player_id=r.host_id and ps.expires_at>now() and ps.last_seen_at>=now()-interval '30 seconds');
  if rid is null then raise exception 'Sala FREE não encontrada.'; end if;
  perform public.jl_ludo_join_room_internal(rid,me);
  delete from public.ludo_waiting_queue where player_id=me;
  return public.jl_ludo_room_state(p_token,rid);
end; $$;

create or replace function public.jl_ludo_accept_free_public_challenge(p_token text,p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$ begin return public.jl_ludo_join_free_public_room(p_token,p_code); end; $$;

create or replace function public.jl_ludo_free_rematch(p_token text,p_room uuid,p_mode text,p_rules jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid:=public.jl_player_id(p_token); r public.ludo_rooms%rowtype; created jsonb; new_room uuid; existing uuid; x record; new_rules jsonb; new_mode text:=lower(trim(coalesce(p_mode,'')));
begin
  perform public.jl_free_access_require(me);
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.id is null or r.status<>'finished' or r.play_mode<>'free' then raise exception 'Partida FREE anterior indisponível.'; end if;
  if not exists(select 1 from public.ludo_room_players where room_id=p_room and player_id=me and status<>'left') then raise exception 'Você não participou desta partida.'; end if;
  if new_mode not in ('solo','partners') then raise exception 'Modo inválido.'; end if;
  if new_mode='partners' and r.player_count<>4 then raise exception 'Parceiros exige 4 jogadores.'; end if;
  select (e.payload->>'new_room')::uuid into existing from public.ludo_events e join public.ludo_rooms nr on nr.id=(e.payload->>'new_room')::uuid where e.room_id=p_room and e.event_type='rematch_created' and nr.play_mode='free' and nr.status in ('waiting','negotiating','funding','playing') order by e.id desc limit 1;
  if existing is not null then if public.jl_ludo_is_member(existing,me) then return public.jl_ludo_room_state(p_token,existing); end if; raise exception 'Já existe uma repetição desta partida.'; end if;
  new_rules:=r.rules||coalesce(p_rules,'{}'::jsonb)||jsonb_build_object('pawn_count',r.pawn_count);
  created:=public.jl_ludo_create_free_room(p_token,r.player_count,new_mode,false,new_rules);
  new_room:=(created->'room'->>'id')::uuid;
  for x in select player_id from public.ludo_room_players where room_id=p_room and status<>'left' and player_id<>me order by seat loop perform public.jl_ludo_invite(p_token,new_room,x.player_id); end loop;
  perform public.jl_ludo_event(p_room,me,'rematch_created',jsonb_build_object('new_room',new_room,'free',true,'player_count',r.player_count,'mode',new_mode,'rules',new_rules));
  return public.jl_ludo_room_state(p_token,new_room);
end; $$;

create or replace function public.jl_ludo_accept_rules(p_token text,p_room uuid,p_accept boolean)
returns jsonb language plpgsql security definer set search_path='public' as $$
declare me uuid:=public.jl_player_id(p_token); r public.ludo_rooms%rowtype; c int; a int;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.id is null or r.status not in ('waiting','negotiating') or not public.jl_ludo_is_member(p_room,me) then raise exception 'Sala indisponível.'; end if;
  if r.play_mode='free' then perform public.jl_free_access_require(me); end if;
  if not p_accept then update public.ludo_room_players set accepted_rules_version=null where room_id=p_room and player_id=me; perform public.jl_ludo_event(p_room,me,'rules_declined',jsonb_build_object('version',r.rules_version)); return public.jl_ludo_room_state(p_token,p_room); end if;
  update public.ludo_room_players set accepted_rules_version=r.rules_version where room_id=p_room and player_id=me and status<>'left';
  perform public.jl_ludo_event(p_room,me,'rules_accepted',jsonb_build_object('version',r.rules_version,'no_deadline',true));
  select count(*),count(*) filter(where accepted_rules_version=r.rules_version) into c,a from public.ludo_room_players where room_id=p_room and status<>'left';
  if c=r.player_count and a=c then
    if r.play_mode='free' then
      if exists(select 1 from public.ludo_room_players rp where rp.room_id=p_room and rp.status<>'left' and not public.jl_free_access_active(rp.player_id)) then raise exception 'Todos os jogadores precisam de FREE ativo.'; end if;
      update public.ludo_room_players set stake_paid=true,stake_amount=0 where room_id=p_room and status<>'left';
      update public.ludo_rooms set status='funding',action_deadline=null,negotiation_grace_used=false,updated_at=now() where id=p_room;
      perform public.jl_ludo_start_game(p_room);
    else
      update public.ludo_rooms set status='funding',action_deadline=now()+make_interval(secs=>(rules->>'stake_seconds')::int),negotiation_grace_used=false,updated_at=now() where id=p_room;
    end if;
    perform public.jl_ludo_event(p_room,me,'rules_unanimous',jsonb_build_object('version',r.rules_version,'free',r.play_mode='free'));
  end if;
  return public.jl_ludo_room_state(p_token,p_room);
end; $$;

create or replace function public.jl_ludo_update_rules(p_token text,p_room uuid,p_rules jsonb)
returns jsonb language plpgsql security definer set search_path='public' as $$
declare me uuid:=public.jl_player_id(p_token); r public.ludo_rooms%rowtype; nr jsonb;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.id is null or not public.jl_ludo_is_member(p_room,me) then raise exception 'Sala indisponível.'; end if;
  if r.status not in ('waiting','negotiating') then raise exception 'As regras já estão bloqueadas para esta partida.'; end if;
  if r.play_mode='free' then perform public.jl_free_access_require(me); end if;
  nr:=public.jl_ludo_rules(p_rules,case when r.play_mode='free' then 10 else r.bet_amount end);
  if r.player_count=2 then nr:=jsonb_set(nr,'{capture_penalty}','"lose_turn"'::jsonb,true); end if;
  if r.play_mode='free' then nr:=jsonb_set(nr,'{capture_penalty}','"lose_turn"'::jsonb,true); nr:=jsonb_set(nr,'{reentry_allowed}','false'::jsonb,true); end if;
  update public.ludo_rooms set rules=nr,rules_version=rules_version+1,status='negotiating',action_deadline=null,negotiation_grace_used=false,updated_at=now() where id=p_room returning * into r;
  update public.ludo_room_players set accepted_rules_version=null where room_id=p_room and status<>'left';
  update public.ludo_room_players set accepted_rules_version=r.rules_version where room_id=p_room and player_id=me and status<>'left';
  perform public.jl_ludo_event(p_room,me,'rules_changed',jsonb_build_object('version',r.rules_version,'rules',nr,'proposed_by',me,'free',r.play_mode='free'));
  return public.jl_ludo_room_state(p_token,p_room);
end; $$;

create or replace function public.jl_ludo_public_challenges(p_token text)
returns jsonb language plpgsql security definer set search_path='public' as $$
declare me uuid:=public.jl_player_id(p_token);
begin
  return coalesce((select jsonb_agg(jsonb_build_object('room_id',r.id,'code',r.code,'host_id',r.host_id,'host_name',p.name,'host_code',public.jl_ludo_display_code(r.host_id),'player_count',r.player_count,'joined_count',x.joined_count,'open_slots',greatest(0,r.player_count-x.joined_count),'mode',r.mode,'bet_amount',r.bet_amount,'status',r.status,'play_location',coalesce(r.rules->>'play_location','online'),'dice_count',coalesce((r.rules->>'dice_count')::int,1),'expires_at',null,'created_at',r.created_at) order by r.updated_at desc)
    from public.ludo_rooms r join public.players p on p.id=r.host_id cross join lateral (select count(*)::int joined_count from public.ludo_room_players rp where rp.room_id=r.id and rp.status<>'left') x
    where r.play_mode='bet' and r.is_public and r.status in ('waiting','negotiating') and r.host_id<>me and x.joined_count<r.player_count
      and exists(select 1 from public.ludo_room_players host_rp where host_rp.room_id=r.id and host_rp.player_id=r.host_id and host_rp.status<>'left')
      and exists(select 1 from public.player_sessions ps where ps.player_id=r.host_id and ps.expires_at>now() and ps.last_seen_at>=now()-interval '30 seconds')
      and not exists(select 1 from public.ludo_room_players mine where mine.room_id=r.id and mine.player_id=me and mine.status<>'left')),'[]'::jsonb);
end; $$;

revoke execute on function public.jl_ludo_create_free_room(text,integer,text,boolean,jsonb) from public;
revoke execute on function public.jl_ludo_create_free_from_board_invite(text,uuid,jsonb) from public;
revoke execute on function public.jl_ludo_free_public_challenges(text) from public;
revoke execute on function public.jl_ludo_join_free_public_room(text,text) from public;
revoke execute on function public.jl_ludo_accept_free_public_challenge(text,text) from public;
revoke execute on function public.jl_ludo_free_rematch(text,uuid,text,jsonb) from public;
grant execute on function public.jl_ludo_create_free_room(text,integer,text,boolean,jsonb) to anon,authenticated;
grant execute on function public.jl_ludo_create_free_from_board_invite(text,uuid,jsonb) to anon,authenticated;
grant execute on function public.jl_ludo_free_public_challenges(text) to anon,authenticated;
grant execute on function public.jl_ludo_join_free_public_room(text,text) to anon,authenticated;
grant execute on function public.jl_ludo_accept_free_public_challenge(text,text) to anon,authenticated;
grant execute on function public.jl_ludo_free_rematch(text,uuid,text,jsonb) to anon,authenticated;

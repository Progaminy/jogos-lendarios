-- Melhoria 7: aceitar regras sem prazo e manter regras padrão quando não houver proposta personalizada.

create or replace function public.jl_ludo_join_room_internal(p_room uuid, p_player uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare r public.ludo_rooms%rowtype; s int; col text; tm int; joined_now int;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.id is null or r.status not in ('waiting','negotiating') then raise exception 'Sala indisponível.'; end if;
  if exists(select 1 from public.ludo_room_players where room_id=p_room and player_id=p_player and status<>'left') then return; end if;
  if exists(select 1 from public.ludo_room_players rp join public.ludo_rooms rr on rr.id=rp.room_id where rp.player_id=p_player and rp.status<>'left' and rr.status in ('waiting','negotiating','funding','playing') and rr.id<>p_room) then raise exception 'O jogador já participa de outra sala ativa.'; end if;
  if (select count(*) from public.ludo_room_players where room_id=p_room and status<>'left') >= r.player_count then raise exception 'Sala cheia.'; end if;

  select x into s from generate_series(1,r.player_count) x
  where not exists(select 1 from public.ludo_room_players where room_id=p_room and seat=x and status<>'left')
  order by x limit 1;

  col := case s when 1 then 'red' when 2 then case when r.player_count=2 then 'yellow' else 'green' end when 3 then 'yellow' else 'blue' end;
  if r.player_count=2 and s=2 then col:='yellow'; end if;
  tm := case when r.mode='partners' then case when s in (1,3) then 1 else 2 end else null end;

  insert into public.ludo_room_players(room_id,player_id,seat,color,team,status)
  values(p_room,p_player,s,col,tm,'active');
  perform public.jl_ludo_ensure_code(p_player);

  update public.ludo_rooms
  set status='negotiating',action_deadline=null,negotiation_grace_used=false,updated_at=now()
  where id=p_room;

  perform public.jl_ludo_event(p_room,p_player,'player_joined',jsonb_build_object('seat',s,'color',col,'team',tm));

  select count(*) into joined_now from public.ludo_room_players where room_id=p_room and status<>'left';
  if joined_now >= r.player_count then
    update public.ludo_invitations i
    set status='cancelled'
    where i.room_id=p_room
      and i.status in ('pending','accepted')
      and i.target_player_id<>p_player
      and not exists(select 1 from public.ludo_room_players rp where rp.room_id=p_room and rp.player_id=i.target_player_id and rp.status<>'left');
  end if;
end;
$$;

create or replace function public.jl_ludo_update_rules(p_token text, p_room uuid, p_rules jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare me uuid:=public.jl_player_id(p_token); r public.ludo_rooms%rowtype; nr jsonb;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.id is null or r.host_id<>me then raise exception 'Apenas o anfitrião pode alterar as regras.'; end if;
  if r.status not in ('waiting','negotiating') then raise exception 'As regras já estão bloqueadas para esta partida.'; end if;

  nr := public.jl_ludo_rules(p_rules,r.bet_amount);
  if r.player_count=2 then nr:=jsonb_set(nr,'{capture_penalty}','"lose_turn"'::jsonb,true); end if;

  update public.ludo_rooms
  set rules=nr,rules_version=rules_version+1,status='negotiating',action_deadline=null,
      negotiation_grace_used=false,updated_at=now()
  where id=p_room returning * into r;

  update public.ludo_room_players set accepted_rules_version=null where room_id=p_room and status<>'left';
  update public.ludo_room_players set accepted_rules_version=r.rules_version where room_id=p_room and player_id=me;

  perform public.jl_ludo_event(p_room,me,'rules_changed',jsonb_build_object('version',r.rules_version,'rules',nr));
  return public.jl_ludo_room_state(p_token,p_room);
end;
$$;

create or replace function public.jl_ludo_accept_rules(p_token text, p_room uuid, p_accept boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare me uuid:=public.jl_player_id(p_token); r public.ludo_rooms%rowtype; c int; a int;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.id is null or r.status not in ('waiting','negotiating') or not public.jl_ludo_is_member(p_room,me) then raise exception 'Sala indisponível.'; end if;

  if not p_accept then
    update public.ludo_room_players set accepted_rules_version=null where room_id=p_room and player_id=me;
    perform public.jl_ludo_event(p_room,me,'rules_declined',jsonb_build_object('version',r.rules_version));
    return public.jl_ludo_room_state(p_token,p_room);
  end if;

  update public.ludo_room_players set accepted_rules_version=r.rules_version where room_id=p_room and player_id=me and status<>'left';
  perform public.jl_ludo_event(p_room,me,'rules_accepted',jsonb_build_object('version',r.rules_version,'no_deadline',true));

  select count(*),count(*) filter(where accepted_rules_version=r.rules_version)
  into c,a
  from public.ludo_room_players
  where room_id=p_room and status<>'left';

  if c=r.player_count and a=c then
    update public.ludo_rooms
    set status='funding',action_deadline=now()+make_interval(secs=>(rules->>'stake_seconds')::int),
        negotiation_grace_used=false,updated_at=now()
    where id=p_room;
    perform public.jl_ludo_event(p_room,me,'rules_unanimous',jsonb_build_object('version',r.rules_version,'accepted_without_deadline',true));
  end if;

  return public.jl_ludo_room_state(p_token,p_room);
end;
$$;

create or replace function public.jl_ludo_sync_room(p_token text, p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare me uuid:=public.jl_player_id(p_token); r public.ludo_rooms%rowtype; joined_count int; accepted_count int; paid_count int; stake_secs int;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.id is null or not public.jl_ludo_is_member(p_room,me) then raise exception 'Sala inválida.'; end if;
  if r.status in ('finished','cancelled','playing') then return public.jl_ludo_room_state(p_token,p_room); end if;

  select count(*) filter(where status<>'left'),
         count(*) filter(where status<>'left' and accepted_rules_version=r.rules_version),
         count(*) filter(where status<>'left' and stake_paid)
  into joined_count,accepted_count,paid_count
  from public.ludo_room_players where room_id=p_room;

  if joined_count=r.player_count and r.status='waiting' then
    update public.ludo_rooms set status='negotiating',action_deadline=null,negotiation_grace_used=false,updated_at=now() where id=p_room;
    r.status:='negotiating';
  end if;

  if joined_count=r.player_count and accepted_count=joined_count and r.status='negotiating' then
    stake_secs:=coalesce((r.rules->>'stake_seconds')::int,60);
    update public.ludo_rooms set status='funding',action_deadline=now()+make_interval(secs=>stake_secs),updated_at=now() where id=p_room;
    perform public.jl_ludo_event(p_room,me,'room_ready_for_stakes',jsonb_build_object('players',joined_count));
    r.status:='funding';
  end if;

  if joined_count=r.player_count and accepted_count=joined_count and paid_count=joined_count and r.status='funding' then
    perform public.jl_ludo_start_game(p_room);
  end if;

  return public.jl_ludo_room_state(p_token,p_room);
end;
$$;

create or replace function public.jl_ludo_process_timeouts(p_token text, p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare me uuid:=public.jl_player_id(p_token); r public.ludo_rooms%rowtype; cur uuid;
begin
  if not public.jl_ludo_is_member(p_room,me) then raise exception 'Você não pertence a esta sala.'; end if;
  select * into r from public.ludo_rooms where id=p_room for update;

  if r.status='funding' and r.action_deadline is not null and r.action_deadline<=now() then
    delete from public.ludo_room_players where room_id=p_room and player_id<>r.host_id and not stake_paid;
    perform public.jl_ludo_refund_room(p_room,'Reembolso: tempo de confirmação da sala expirou');
    update public.ludo_room_players set accepted_rules_version=case when player_id=r.host_id then r.rules_version else null end where room_id=p_room;
    update public.ludo_rooms set status='waiting',action_deadline=null,negotiation_grace_used=false,updated_at=now() where id=p_room;
    perform public.jl_ludo_event(p_room,null,'funding_timeout','{}'::jsonb);
  elsif r.status='playing' then
    if public.jl_ludo_check_finish(p_room) then return public.jl_ludo_room_state(p_token,p_room); end if;
    if r.action_deadline is not null and r.action_deadline<=now() and r.current_player_id is not null then
      cur:=r.current_player_id;
      update public.ludo_room_players set timeout_strikes=timeout_strikes+1 where room_id=p_room and player_id=cur;
      perform public.jl_ludo_event(p_room,cur,'action_timeout',jsonb_build_object('phase',r.turn_phase,'action','turn_passed','player_remains_in_game',true));
      perform public.jl_ludo_advance_turn(p_room,cur,false);
    end if;
  end if;

  return public.jl_ludo_room_state(p_token,p_room);
end;
$$;

update public.ludo_rooms
set action_deadline=null,negotiation_grace_used=false,updated_at=now()
where status='negotiating';

-- Melhoria 4: timeout da jogada apenas passa a vez; desistência é explícita.
-- Aplicado no Supabase em 2026-09-22.

create or replace function public.jl_ludo_process_timeouts(p_token text, p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  cur uuid;
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

create or replace function public.jl_ludo_forfeit(p_token text, p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare me uuid:=public.jl_player_id(p_token); r public.ludo_rooms%rowtype; rp public.ludo_room_players%rowtype;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  select * into rp from public.ludo_room_players where room_id=p_room and player_id=me for update;
  if r.id is null or rp.player_id is null then raise exception 'Sala inválida.'; end if;
  if r.status<>'playing' then raise exception 'Só é possível desistir depois de a partida começar.'; end if;
  if rp.status not in ('active','reentry') then raise exception 'Este jogador já não está ativo na partida.'; end if;
  update public.ludo_room_players set status='eliminated',reentry_deadline=null where room_id=p_room and player_id=me;
  perform public.jl_ludo_event(p_room,me,'player_forfeited',jsonb_build_object('explicit',true));
  if r.current_player_id=me then perform public.jl_ludo_advance_turn(p_room,me,false); else perform public.jl_ludo_check_finish(p_room); end if;
  return jsonb_build_object('ok',true,'forfeited',true);
end;
$$;

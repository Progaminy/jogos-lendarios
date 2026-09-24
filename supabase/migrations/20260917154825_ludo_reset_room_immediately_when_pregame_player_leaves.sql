create or replace function public.jl_ludo_cancel_or_leave(p_token text, p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  rp public.ludo_room_players%rowtype;
  joined_after int;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  select * into rp from public.ludo_room_players where room_id=p_room and player_id=me for update;
  if r.id is null or rp.player_id is null then raise exception 'Sala inválida.'; end if;
  if r.status in ('finished','cancelled') then return jsonb_build_object('ok',true); end if;

  if r.status<>'playing' then
    if r.host_id=me then
      perform public.jl_ludo_refund_room(p_room,'Reembolso: sala cancelada pelo anfitrião');
      update public.ludo_rooms
      set status='cancelled',action_deadline=null,negotiation_grace_used=false,updated_at=now()
      where id=p_room;
      update public.ludo_room_players set status='left' where room_id=p_room;
      update public.ludo_invitations set status='cancelled' where room_id=p_room and status in ('pending','accepted');
    else
      if r.status='funding' then
        perform public.jl_ludo_refund_room(p_room,'Reembolso: jogador saiu antes do início');
      elsif rp.stake_paid then
        update public.players set balance=balance+rp.stake_amount,updated_at=now() where id=me;
        insert into public.transactions(player_id,kind,amount,status,reference_id,note)
        values(me,'ludo_refund',rp.stake_amount,'completed',p_room,'Reembolso: saída antes do início');
        update public.ludo_rooms set pot=greatest(0,pot-rp.stake_amount),updated_at=now() where id=p_room;
      end if;

      update public.ludo_room_players
      set status='left',stake_paid=false,stake_amount=0
      where room_id=p_room and player_id=me;

      select count(*) into joined_after
      from public.ludo_room_players
      where room_id=p_room and status<>'left';

      if joined_after<r.player_count then
        update public.ludo_rooms
        set status='waiting',action_deadline=null,negotiation_grace_used=false,updated_at=now()
        where id=p_room;
      end if;
    end if;
  else
    update public.ludo_room_players set status='eliminated' where room_id=p_room and player_id=me;
    perform public.jl_ludo_event(p_room,me,'player_left_game','{}'::jsonb);
    if r.current_player_id=me then
      perform public.jl_ludo_advance_turn(p_room,me,false);
    else
      perform public.jl_ludo_check_finish(p_room);
    end if;
  end if;

  return jsonb_build_object('ok',true);
end;
$function$;

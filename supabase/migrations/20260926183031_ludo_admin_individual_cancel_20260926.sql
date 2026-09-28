
create or replace function public.jl_admin_ludo_active_rooms(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_rooms jsonb;
begin
  if not public.jl_admin_ok(p_token) then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', r.id,
        'code', r.code,
        'status', r.status,
        'mode', r.mode,
        'player_count', r.player_count,
        'bet_amount', r.bet_amount,
        'pot', r.pot,
        'created_at', r.created_at,
        'active_players', (
          select count(*)
          from public.ludo_room_players rp
          where rp.room_id = r.id
            and rp.status <> 'left'
        ),
        'staked_total', (
          select coalesce(sum(rp.stake_amount), 0)
          from public.ludo_room_players rp
          where rp.room_id = r.id
            and rp.stake_paid
        )
      )
      order by r.created_at desc
    ),
    '[]'::jsonb
  )
  into v_rooms
  from public.ludo_rooms r
  where r.status not in ('finished', 'cancelled');

  return v_rooms;
end;
$function$;

create or replace function public.jl_admin_cancel_ludo_room(
  p_token text,
  p_room uuid,
  p_reason text default 'Cancelamento administrativo de partida'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_room public.ludo_rooms%rowtype;
  v_refunded numeric := 0;
  v_reason text := left(
    coalesce(nullif(trim(p_reason), ''), 'Cancelamento administrativo de partida'),
    220
  );
begin
  if not public.jl_admin_ok(p_token) then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  select *
  into v_room
  from public.ludo_rooms
  where id = p_room
  for update;

  if v_room.id is null then
    raise exception 'Sala de Ludo não encontrada.';
  end if;

  if v_room.status in ('finished', 'cancelled') then
    return jsonb_build_object(
      'ok', true,
      'already_closed', true,
      'room_id', v_room.id,
      'room_code', v_room.code,
      'cancelled_rooms', 0,
      'refunded_total', 0,
      'message', 'Esta partida já estava encerrada.'
    );
  end if;

  select coalesce(sum(stake_amount), 0)
  into v_refunded
  from public.ludo_room_players
  where room_id = p_room
    and stake_paid;

  perform public.jl_ludo_refund_room(
    p_room,
    'Reembolso administrativo: ' || v_reason
  );

  update public.ludo_rooms
  set status = 'cancelled',
      action_deadline = null,
      public_challenge_expires_at = null,
      negotiation_grace_used = false,
      current_player_id = null,
      dice_result = null,
      turn_phase = null,
      updated_at = now()
  where id = p_room;

  update public.ludo_room_players
  set status = 'left'
  where room_id = p_room;

  update public.ludo_invitations
  set status = 'cancelled'
  where room_id = p_room
    and status in ('pending', 'accepted');

  delete from public.ludo_waiting_queue q
  where q.player_id in (
    select rp.player_id
    from public.ludo_room_players rp
    where rp.room_id = p_room
  );

  insert into public.audit_log(action, details)
  values(
    'ludo_admin_cancel_room',
    jsonb_build_object(
      'reason', v_reason,
      'room_id', v_room.id,
      'room_code', v_room.code,
      'previous_status', v_room.status,
      'refunded_total', v_refunded,
      'performed_at', now()
    )
  );

  return jsonb_build_object(
    'ok', true,
    'already_closed', false,
    'room_id', v_room.id,
    'room_code', v_room.code,
    'cancelled_rooms', 1,
    'refunded_total', v_refunded,
    'message', 'Partida do Ludo cancelada e apostas devolvidas.'
  );
end;
$function$;

revoke execute on function public.jl_admin_ludo_active_rooms(text) from public, authenticated;
revoke execute on function public.jl_admin_cancel_ludo_room(text, uuid, text) from public, authenticated;
grant execute on function public.jl_admin_ludo_active_rooms(text) to anon, service_role;
grant execute on function public.jl_admin_cancel_ludo_room(text, uuid, text) to anon, service_role;

revoke execute on function public.jl_admin_ludo_emergency_status(text) from public, authenticated;
revoke execute on function public.jl_admin_cancel_all_ludo(text, text) from public, authenticated;
grant execute on function public.jl_admin_ludo_emergency_status(text) to anon, service_role;
grant execute on function public.jl_admin_cancel_all_ludo(text, text) to anon, service_role;

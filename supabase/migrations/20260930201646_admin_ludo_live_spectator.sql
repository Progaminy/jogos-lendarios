-- Admin Ludo spectator: snapshot somente-leitura de qualquer sala.
-- O admin não entra na sala, não ocupa assento e não participa da lógica do jogo.

create or replace function public.jl_admin_ludo_watch_room(
  p_token text,
  p_room uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  r public.ludo_rooms%rowtype;
  v_players jsonb;
  v_tokens jsonb;
  v_events jsonb;
begin
  if not public.jl_admin_ok(p_token) then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  select *
  into r
  from public.ludo_rooms
  where id=p_room;

  if r.id is null then
    raise exception 'Sala de Ludo não encontrada.';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'player_id',rp.player_id,
        'name',p.name,
        'code',public.jl_ludo_display_code(rp.player_id),
        'seat',rp.seat,
        'color',rp.color,
        'team',rp.team,
        'status',rp.status,
        'stake_paid',rp.stake_paid,
        'stake_amount',rp.stake_amount,
        'pawn_style',coalesce(rp.pawn_style,'current'),
        'timeout_strikes',rp.timeout_strikes
      )
      order by rp.seat
    ),
    '[]'::jsonb
  )
  into v_players
  from public.ludo_room_players rp
  join public.players p on p.id=rp.player_id
  where rp.room_id=p_room
    and rp.status<>'left';

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'player_id',t.player_id,
        'token_no',t.token_no,
        'steps',t.steps
      )
      order by rp.seat,t.token_no
    ),
    '[]'::jsonb
  )
  into v_tokens
  from public.ludo_tokens t
  join public.ludo_room_players rp
    on rp.room_id=t.room_id
   and rp.player_id=t.player_id
  where t.room_id=p_room
    and rp.status<>'left';

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',e.id,
        'player_id',e.player_id,
        'event_type',e.event_type,
        'payload',e.payload,
        'created_at',e.created_at
      )
      order by e.id
    ),
    '[]'::jsonb
  )
  into v_events
  from (
    select id,player_id,event_type,payload,created_at
    from public.ludo_events
    where room_id=p_room
    order by id desc
    limit 20
  ) e;

  return jsonb_build_object(
    'server_now',now(),
    'room',jsonb_build_object(
      'id',r.id,
      'code',r.code,
      'status',r.status,
      'mode',r.mode,
      'player_count',r.player_count,
      'bet_amount',r.bet_amount,
      'pot',r.pot,
      'host_id',r.host_id,
      'current_player_id',r.current_player_id,
      'turn_phase',r.turn_phase,
      'dice_result',r.dice_result,
      'action_deadline',r.action_deadline,
      'winner_player_id',r.winner_player_id,
      'winner_team',r.winner_team,
      'created_at',r.created_at,
      'updated_at',r.updated_at,
      'finished_at',r.finished_at
    ),
    'players',v_players,
    'tokens',v_tokens,
    'events',v_events
  );
end;
$function$;

revoke execute on function public.jl_admin_ludo_watch_room(text,uuid)
from public,authenticated;

grant execute on function public.jl_admin_ludo_watch_room(text,uuid)
to anon,service_role;

create or replace function public.jl_ludo_defaults()
returns jsonb
language sql
immutable
set search_path = public
as $function$
  select jsonb_build_object(
    'turn_seconds',30,
    'move_seconds',30,
    'rules_response_seconds',60,
    'stake_seconds',60,
    'reentry_seconds',60,
    'capture_required',false,
    'capture_penalty','eliminate_reentry',
    'reentry_allowed',true,
    'reentry_amount',10,
    'partner_capture',false,
    'capture_extra_turn',true,
    'six_extra_turn',true,
    'three_sixes_penalty',true,
    'safe_cells',true,
    'blockades',false,
    'exact_finish',true,
    'base_exit_rule','six',
    'idle_strikes_limit',3,
    'voice_enabled',true,
    'chat_enabled',true,
    'private_room',true,
    'play_location','online',
    'dice_count',1
  );
$function$;

create or replace function public.jl_ludo_choose_color(
  p_token text,
  p_room uuid,
  p_color text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  me uuid := public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  rp public.ludo_room_players%rowtype;
  wanted text := lower(trim(coalesce(p_color,'')));
begin
  if wanted not in ('red','green','yellow','blue') then
    raise exception 'Cor inválida.';
  end if;

  select * into r
  from public.ludo_rooms
  where id = p_room
  for update;

  if r.id is null or r.status not in ('waiting','negotiating') then
    raise exception 'A cor só pode ser escolhida antes da confirmação da partida.';
  end if;

  select * into rp
  from public.ludo_room_players
  where room_id = p_room
    and player_id = me
    and status <> 'left'
  for update;

  if rp.player_id is null then
    raise exception 'Jogador não pertence a esta sala.';
  end if;

  if rp.color = wanted then
    return public.jl_ludo_room_state(p_token,p_room);
  end if;

  if exists (
    select 1
    from public.ludo_room_players x
    where x.room_id = p_room
      and x.player_id <> me
      and x.status <> 'left'
      and x.color = wanted
  ) then
    raise exception 'Esta cor já está ocupada.';
  end if;

  update public.ludo_room_players
  set color = wanted
  where room_id = p_room
    and player_id = me;

  perform public.jl_ludo_event(
    p_room,
    me,
    'color_selected',
    jsonb_build_object('from',rp.color,'to',wanted)
  );

  return public.jl_ludo_room_state(p_token,p_room);
end;
$function$;

revoke execute on function public.jl_ludo_choose_color(text,uuid,text) from public;
revoke execute on function public.jl_ludo_choose_color(text,uuid,text) from anon, authenticated;
grant execute on function public.jl_ludo_choose_color(text,uuid,text) to anon, authenticated;

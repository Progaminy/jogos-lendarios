alter table public.ludo_room_players
  add column if not exists pawn_style text not null default 'current';

alter table public.ludo_room_players
  drop constraint if exists ludo_room_players_pawn_style_check;

alter table public.ludo_room_players
  add constraint ludo_room_players_pawn_style_check
  check (pawn_style in ('current','classic','video'));

create or replace function public.jl_ludo_choose_pawn_style(
  p_token text,
  p_room uuid,
  p_pawn_style text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  me uuid := public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  rp public.ludo_room_players%rowtype;
  wanted text := lower(trim(coalesce(p_pawn_style,'')));
begin
  if wanted not in ('current','classic','video') then
    raise exception 'Tipo de peão inválido.';
  end if;

  select * into r
  from public.ludo_rooms
  where id=p_room
  for update;

  if r.id is null or r.status not in ('waiting','negotiating','funding') then
    raise exception 'O tipo de peão só pode ser escolhido antes da partida começar.';
  end if;

  select * into rp
  from public.ludo_room_players
  where room_id=p_room
    and player_id=me
    and status<>'left'
  for update;

  if rp.player_id is null then
    raise exception 'Jogador não pertence a esta sala.';
  end if;

  if rp.pawn_style=wanted then
    return public.jl_ludo_room_state(p_token,p_room);
  end if;

  update public.ludo_room_players
  set pawn_style=wanted
  where room_id=p_room
    and player_id=me;

  perform public.jl_ludo_event(
    p_room,
    me,
    'pawn_style_selected',
    jsonb_build_object('from',rp.pawn_style,'to',wanted)
  );

  return public.jl_ludo_room_state(p_token,p_room);
end;
$function$;

create or replace function public.jl_ludo_room_state_light(p_token text, p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  mymoves jsonb:='[]'::jsonb;
  ident jsonb;
begin
  select * into r
  from public.ludo_rooms
  where id=p_room;

  if r.id is null or not public.jl_ludo_is_member(p_room,me) then
    raise exception 'Sala de Ludo não encontrada.';
  end if;

  if r.status='playing'
     and r.current_player_id=me
     and r.turn_phase='move'
     and r.dice_result is not null then
    mymoves:=public.jl_ludo_legal_moves_data(p_room,me,r.dice_result);
  end if;

  ident:=jsonb_build_object(
    'player_id',me,
    'code',public.jl_ludo_display_code(me),
    'house_number',(select house_number from public.ludo_player_codes where player_id=me)
  );

  return jsonb_build_object(
    'identity',ident,
    'room',to_jsonb(r),
    'players',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'player_id',rp.player_id,
          'name',p.name,
          'code',coalesce(nullif(split_part(trim(p.name),' ',1),''),'Jogador') || lpad(c.house_number::text,3,'0'),
          'house_number',c.house_number,
          'seat',rp.seat,
          'color',rp.color,
          'pawn_style',rp.pawn_style,
          'team',rp.team,
          'accepted_rules_version',rp.accepted_rules_version,
          'stake_paid',rp.stake_paid,
          'stake_amount',rp.stake_amount,
          'status',rp.status,
          'timeout_strikes',rp.timeout_strikes,
          'reentry_deadline',rp.reentry_deadline
        )
        order by rp.seat
      )
      from public.ludo_room_players rp
      join public.players p on p.id=rp.player_id
      join public.ludo_player_codes c on c.player_id=rp.player_id
      where rp.room_id=p_room
        and rp.status<>'left'
    ),'[]'::jsonb),
    'tokens',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'player_id',t.player_id,
          'token_no',t.token_no,
          'steps',t.steps
        )
        order by rp.seat,t.token_no
      )
      from public.ludo_tokens t
      join public.ludo_room_players rp
        on rp.room_id=t.room_id
       and rp.player_id=t.player_id
      where t.room_id=p_room
    ),'[]'::jsonb),
    'legal_moves',mymoves
  );
end;
$function$;

revoke execute on function public.jl_ludo_choose_pawn_style(text,uuid,text) from public;
revoke execute on function public.jl_ludo_choose_pawn_style(text,uuid,text) from anon, authenticated;
grant execute on function public.jl_ludo_choose_pawn_style(text,uuid,text) to anon, authenticated;

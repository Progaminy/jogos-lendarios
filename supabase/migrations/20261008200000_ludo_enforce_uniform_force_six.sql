-- Ludo Lendário — regra uniforme para todos os jogadores.
-- Corrige qualquer definição anterior que tenha reintroduzido exceções por UUID.
-- Regra: após 6 lançamentos sem 6, a 7ª tentativa é forçada para 6.

create or replace function public.jl_ludo_roll(p_token text, p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  d int;
  moves jsonb;
  rp public.ludo_room_players%rowtype;
  dc int;
  vals jsonb:='[]'::jsonb;
  i int;
  force_six boolean:=false;
  saw_six boolean:=false;
  turn_secs int;
begin
  perform public.jl_ludo_process_timeouts(p_token,p_room);

  select * into r
  from public.ludo_rooms
  where id=p_room
  for update;

  if r.status<>'playing' or r.current_player_id<>me or r.turn_phase<>'roll' then
    raise exception 'Não é hora de lançar o dado.';
  end if;

  if r.started_at is null then
    turn_secs := (r.rules->>'turn_seconds')::int;

    update public.ludo_rooms
    set started_at=now(),
        action_deadline=now()+make_interval(secs=>turn_secs),
        updated_at=now()
    where id=p_room
    returning * into r;

    perform public.jl_ludo_event(
      p_room,me,'game_started',
      jsonb_build_object(
        'first_player',me,
        'deadline',r.action_deadline,
        'turn_seconds',turn_secs
      )
    );
  end if;

  if r.action_deadline is null or r.action_deadline<=now() then
    raise exception 'Tempo da jogada expirou.';
  end if;

  select * into rp
  from public.ludo_room_players
  where room_id=p_room and player_id=me
  for update;

  dc := coalesce((r.rules->>'dice_count')::int,1);

  -- Regra única para todos: 6 falhas -> 6 forçado na 7ª tentativa.
  force_six := coalesce(rp.rolls_without_six,0) >= 6;

  if dc=1 then
    d:=case when force_six then 6 else public.jl_random_index(6) end;

    update public.ludo_room_players
    set consecutive_sixes=case when d=6 then consecutive_sixes+1 else 0 end,
        rolls_without_six=case when d=6 then 0 else rolls_without_six+1 end
    where room_id=p_room and player_id=me
    returning * into rp;

    perform public.jl_ludo_event(
      p_room,me,'dice_rolled',
      jsonb_build_object(
        'dice',d,
        'count',1,
        'forced_six_after_misses',force_six
      )
    );

    if d=6
       and (r.rules->>'three_sixes_penalty')::boolean
       and rp.consecutive_sixes>=3 then
      perform public.jl_ludo_event(
        p_room,me,'three_sixes_penalty',jsonb_build_object('dice',d)
      );
      perform public.jl_ludo_advance_turn(p_room,me,false);
      return public.jl_ludo_room_state(p_token,p_room);
    end if;

    moves:=public.jl_ludo_legal_moves_data(p_room,me,d);

    if jsonb_array_length(moves)=0 then
      perform public.jl_ludo_event(
        p_room,me,'no_legal_move',jsonb_build_object('dice',d)
      );
      perform public.jl_ludo_advance_turn(p_room,me,false);
    else
      update public.ludo_rooms
      set dice_result=d,
          dice_values=jsonb_build_array(d),
          dice_position=0,
          turn_phase='move',
          updated_at=now()
      where id=p_room;
    end if;
  else
    update public.ludo_room_players
    set consecutive_sixes=0
    where room_id=p_room and player_id=me;

    for i in 1..dc loop
      d:=case when force_six and i=1 then 6 else public.jl_random_index(6) end;
      if d=6 then saw_six:=true; end if;
      vals:=vals||jsonb_build_array(d);
    end loop;

    update public.ludo_room_players
    set rolls_without_six=case when saw_six then 0 else rolls_without_six+1 end
    where room_id=p_room and player_id=me
    returning * into rp;

    update public.ludo_rooms
    set dice_values=vals,
        dice_position=-1,
        dice_result=null,
        updated_at=now()
    where id=p_room;

    perform public.jl_ludo_event(
      p_room,me,'dice_rolled',
      jsonb_build_object(
        'dice_values',vals,
        'count',dc,
        'forced_six_after_misses',force_six
      )
    );

    perform public.jl_ludo_continue_multi_dice(p_room,me);
  end if;

  return public.jl_ludo_room_state(p_token,p_room);
end;
$function$;

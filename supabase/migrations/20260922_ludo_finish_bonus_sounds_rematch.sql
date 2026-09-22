-- Melhoria 8: jogada extra ao chegar ao fim, microfone individual e revanche.

alter table public.ludo_rooms
add column if not exists finish_bonus_pending boolean not null default false;

CREATE OR REPLACE FUNCTION public.jl_ludo_advance_turn(p_room uuid, p_current uuid, p_extra boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r public.ludo_rooms%rowtype;
  curseat int;
  nxt uuid;
  secs int;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.status<>'playing' then return; end if;
  if public.jl_ludo_check_finish(p_room) then return; end if;

  secs:=(r.rules->>'turn_seconds')::int;

  if p_extra and exists(
    select 1 from public.ludo_room_players
    where room_id=p_room and player_id=p_current and status='active'
  ) then
    nxt:=p_current;
  else
    select seat into curseat
    from public.ludo_room_players
    where room_id=p_room and player_id=p_current;

    select player_id into nxt
    from public.ludo_room_players
    where room_id=p_room and status='active' and seat>coalesce(curseat,0)
    order by seat limit 1;

    if nxt is null then
      select player_id into nxt
      from public.ludo_room_players
      where room_id=p_room and status='active'
      order by seat limit 1;
    end if;
  end if;

  if nxt is null then
    perform public.jl_ludo_check_finish(p_room);
    return;
  end if;

  if nxt<>p_current then
    update public.ludo_room_players
    set consecutive_sixes=0
    where room_id=p_room and player_id=p_current;
  end if;

  update public.ludo_rooms
  set current_player_id=nxt,
      turn_phase='roll',
      dice_result=null,
      dice_values='[]'::jsonb,
      dice_position=-1,
      finish_bonus_pending=false,
      action_deadline=now()+make_interval(secs=>secs),
      updated_at=now()
  where id=p_room;

  perform public.jl_ludo_event(
    p_room,nxt,'turn_started',
    jsonb_build_object(
      'deadline',now()+make_interval(secs=>secs),
      'extra_turn',p_extra
    )
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.jl_ludo_continue_multi_dice(p_room uuid, p_player uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r public.ludo_rooms%rowtype;
  idx integer;
  total integer;
  d integer;
  moves jsonb;
  move_secs integer;
  bonus boolean:=false;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.status<>'playing' or r.current_player_id<>p_player then return false; end if;

  total := jsonb_array_length(coalesce(r.dice_values,'[]'::jsonb));
  idx := coalesce(r.dice_position,-1) + 1;
  move_secs := (r.rules->>'move_seconds')::int;

  while idx < total loop
    d := (r.dice_values->>idx)::integer;
    moves := public.jl_ludo_legal_moves_data(p_room,p_player,d);

    if jsonb_array_length(moves) > 0 then
      update public.ludo_rooms
      set dice_position=idx,
          dice_result=d,
          turn_phase='move',
          action_deadline=now()+make_interval(secs=>move_secs),
          updated_at=now()
      where id=p_room;

      perform public.jl_ludo_event(
        p_room,p_player,'multi_die_ready',
        jsonb_build_object('position',idx,'dice',d,'total',total)
      );
      return true;
    end if;

    perform public.jl_ludo_event(
      p_room,p_player,'multi_die_skipped',
      jsonb_build_object('position',idx,'dice',d,'reason','no_legal_move')
    );

    idx := idx + 1;
  end loop;

  select coalesce(finish_bonus_pending,false)
  into bonus
  from public.ludo_rooms
  where id=p_room;

  perform public.jl_ludo_advance_turn(p_room,p_player,bonus);
  return false;
end;
$function$;

CREATE OR REPLACE FUNCTION public.jl_ludo_move(p_token text, p_room uuid, p_token_no integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  moves jsonb;
  m jsonb;
  cap_exists bool;
  selected_capture bool;
  ns int;
  c jsonb;
  target uuid;
  target_no int;
  extra bool:=false;
  dc int;
begin
  perform public.jl_ludo_process_timeouts(p_token,p_room);
  select * into r from public.ludo_rooms where id=p_room for update;

  if r.status<>'playing' or r.current_player_id<>me or r.turn_phase<>'move' or r.dice_result is null then
    raise exception 'Não há peça aguardando movimento.';
  end if;
  if r.action_deadline<=now() then raise exception 'Tempo para escolher a peça expirou.'; end if;

  moves:=public.jl_ludo_legal_moves_data(p_room,me,r.dice_result);
  select value into m
  from jsonb_array_elements(moves)
  where (value->>'token_no')::int=p_token_no
  limit 1;

  if m is null then raise exception 'Movimento inválido para este dado.'; end if;

  select exists(
    select 1 from jsonb_array_elements(moves) z
    where (z->>'is_capture')::boolean
  ) into cap_exists;

  selected_capture:=(m->>'is_capture')::boolean;

  if (r.rules->>'capture_required')::boolean and cap_exists and not selected_capture then
    perform public.jl_ludo_apply_capture_penalty(p_room,me);
    return public.jl_ludo_room_state(p_token,p_room);
  end if;

  ns:=(m->>'to_steps')::int;

  update public.ludo_tokens
  set steps=ns,updated_at=now()
  where room_id=p_room and player_id=me and token_no=p_token_no;

  if ns=56 then
    update public.ludo_rooms
    set finish_bonus_pending=true,updated_at=now()
    where id=p_room;
  end if;

  for c in select value from jsonb_array_elements(m->'captures') loop
    target:=(c->>'player_id')::uuid;
    target_no:=(c->>'token_no')::int;

    update public.ludo_tokens
    set steps=-1,updated_at=now()
    where room_id=p_room and player_id=target and token_no=target_no;

    perform public.jl_ludo_event(
      p_room,me,'token_captured',
      jsonb_build_object(
        'victim',target,
        'victim_token',target_no,
        'by_token',p_token_no
      )
    );
  end loop;

  perform public.jl_ludo_event(
    p_room,me,'token_moved',
    jsonb_build_object(
      'token_no',p_token_no,
      'dice',r.dice_result,
      'dice_position',r.dice_position,
      'from_steps',(m->>'from_steps')::int,
      'to_steps',ns,
      'capture',selected_capture,
      'finished_token',ns=56
    )
  );

  if public.jl_ludo_check_finish(p_room) then
    return public.jl_ludo_room_state(p_token,p_room);
  end if;

  dc:=coalesce((r.rules->>'dice_count')::int,1);

  if dc>1 then
    perform public.jl_ludo_continue_multi_dice(p_room,me);
  else
    extra := (ns=56)
      or (r.dice_result=6 and (r.rules->>'six_extra_turn')::boolean)
      or (selected_capture and (r.rules->>'capture_extra_turn')::boolean);

    perform public.jl_ludo_advance_turn(p_room,me,extra);
  end if;

  return public.jl_ludo_room_state(p_token,p_room);
end;
$function$;

CREATE OR REPLACE FUNCTION public.jl_ludo_rematch(p_token text, p_room uuid, p_bet_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  created jsonb;
  new_room uuid;
  existing uuid;
  x record;
  copied_rules jsonb;
begin
  select * into r
  from public.ludo_rooms
  where id=p_room
  for update;

  if r.id is null or r.status<>'finished' then
    raise exception 'A partida anterior ainda não terminou.';
  end if;

  if not exists(
    select 1 from public.ludo_room_players
    where room_id=p_room and player_id=me and status<>'left'
  ) then
    raise exception 'Você não participou desta partida.';
  end if;

  if p_bet_amount is null
     or p_bet_amount<10
     or p_bet_amount<>trunc(p_bet_amount) then
    raise exception 'A nova aposta deve ser um valor inteiro de pelo menos 10 MZN.';
  end if;

  select (e.payload->>'new_room')::uuid
  into existing
  from public.ludo_events e
  join public.ludo_rooms nr
    on nr.id=(e.payload->>'new_room')::uuid
  where e.room_id=p_room
    and e.event_type='rematch_created'
    and nr.status in ('waiting','negotiating','funding','playing')
  order by e.id desc
  limit 1;

  if existing is not null then
    if public.jl_ludo_is_member(existing,me) then
      return public.jl_ludo_room_state(p_token,existing);
    end if;
    raise exception 'Já existe uma repetição desta partida. Veja o convite nas notificações particulares.';
  end if;

  copied_rules:=jsonb_set(r.rules,'{voice_enabled}','true'::jsonb,true);

  created:=public.jl_ludo_create_room(
    p_token,
    r.player_count,
    p_bet_amount,
    r.mode,
    false,
    copied_rules
  );

  new_room:=((created->'room'->>'id')::uuid);

  for x in
    select player_id
    from public.ludo_room_players
    where room_id=p_room
      and status<>'left'
      and player_id<>me
    order by seat
  loop
    perform public.jl_ludo_invite(p_token,new_room,x.player_id);
  end loop;

  perform public.jl_ludo_event(
    p_room,
    me,
    'rematch_created',
    jsonb_build_object(
      'new_room',new_room,
      'bet_amount',p_bet_amount,
      'player_count',r.player_count,
      'mode',r.mode
    )
  );

  return public.jl_ludo_room_state(p_token,new_room);
end;
$function$;

CREATE OR REPLACE FUNCTION public.jl_ludo_rules(p_rules jsonb, p_bet numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
declare
  r jsonb := public.jl_ludo_defaults() || coalesce(p_rules,'{}'::jsonb);
  n numeric;
  dc integer;
  loc text;
begin
  if (r->>'turn_seconds')::integer not between 30 and 120 then raise exception 'Tempo de jogada deve estar entre 30 e 120 segundos.'; end if;
  if (r->>'move_seconds')::integer not between 15 and 60 then raise exception 'Tempo para escolher a peça deve estar entre 15 e 60 segundos.'; end if;
  if (r->>'rules_response_seconds')::integer not between 30 and 60 then raise exception 'Tempo de resposta das regras deve estar entre 30 e 60 segundos.'; end if;
  if (r->>'stake_seconds')::integer not between 30 and 60 then raise exception 'Tempo para confirmar aposta deve estar entre 30 e 60 segundos.'; end if;
  if (r->>'reentry_seconds')::integer not between 30 and 60 then raise exception 'Tempo de reentrada deve estar entre 30 e 60 segundos.'; end if;
  if (r->>'idle_strikes_limit')::integer not between 1 and 5 then raise exception 'Limite de ausências deve estar entre 1 e 5.'; end if;
  if r->>'capture_penalty' not in ('lose_turn','eliminate','eliminate_reentry') then raise exception 'Penalização de captura obrigatória inválida.'; end if;
  if r->>'base_exit_rule' not in ('six','one_or_six') then raise exception 'Regra de saída da base inválida.'; end if;

  n := (r->>'reentry_amount')::numeric;
  if n < 10 or n > p_bet then raise exception 'Valor de reentrada deve ficar entre 10 MZN e a aposta da sala.'; end if;

  loc := coalesce(r->>'play_location','online');
  if loc not in ('online','presential') then raise exception 'Local da partida deve ser online ou presencial.'; end if;

  dc := coalesce((r->>'dice_count')::integer,1);
  if dc not in (1,2,3,4) then raise exception 'Quantidade de dados deve ser 1, 2, 3 ou 4.'; end if;

  if dc > 1 then
    r := jsonb_set(r,'{six_extra_turn}','false'::jsonb,true);
    r := jsonb_set(r,'{capture_extra_turn}','false'::jsonb,true);
    r := jsonb_set(r,'{three_sixes_penalty}','false'::jsonb,true);
  end if;

  -- O microfone é uma escolha individual durante a partida.
  r := jsonb_set(r,'{voice_enabled}','true'::jsonb,true);

  return r;
end;
$function$;

update public.ludo_rooms
set rules=jsonb_set(rules,'{voice_enabled}','true'::jsonb,true), updated_at=now()
where status in ('waiting','negotiating','funding','playing')
  and coalesce((rules->>'voice_enabled')::boolean,false)=false;

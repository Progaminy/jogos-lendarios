-- Ludo Lendário
-- 1) criador escolhe 10/15/20/25/30 segundos por jogada;
-- 2) um único relógio cobre dado + movimento;
-- 3) antes do primeiro dado não existe prazo e cancelar não penaliza.

create or replace function public.jl_ludo_rules(p_rules jsonb, p_bet numeric)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  r jsonb := public.jl_ludo_defaults() || coalesce(p_rules,'{}'::jsonb);
  n numeric;
  dc integer;
  loc text;
  turn_secs integer;
begin
  turn_secs := coalesce((r->>'turn_seconds')::integer,30);
  if turn_secs not in (10,15,20,25,30) then
    raise exception 'Tempo de jogada deve ser 10, 15, 20, 25 ou 30 segundos.';
  end if;

  -- O tempo escolhido é da jogada inteira. Não há um segundo relógio após lançar o dado.
  r := jsonb_set(r,'{turn_seconds}',to_jsonb(turn_secs),true);
  r := jsonb_set(r,'{move_seconds}',to_jsonb(turn_secs),true);

  if (r->>'rules_response_seconds')::integer not between 30 and 60 then
    raise exception 'Tempo de resposta das regras deve estar entre 30 e 60 segundos.';
  end if;
  if (r->>'stake_seconds')::integer not between 30 and 60 then
    raise exception 'Tempo para confirmar aposta deve estar entre 30 e 60 segundos.';
  end if;
  if (r->>'reentry_seconds')::integer not between 30 and 60 then
    raise exception 'Tempo de reentrada deve estar entre 30 e 60 segundos.';
  end if;
  if (r->>'idle_strikes_limit')::integer not between 1 and 5 then
    raise exception 'Limite de ausências deve estar entre 1 e 5.';
  end if;
  if r->>'capture_penalty' not in ('lose_turn','eliminate','eliminate_reentry') then
    raise exception 'Penalização de captura obrigatória inválida.';
  end if;

  n := (r->>'reentry_amount')::numeric;
  if n < 10 or n > p_bet then
    raise exception 'Valor de reentrada deve ficar entre 10 MZN e a aposta da sala.';
  end if;

  loc := coalesce(r->>'play_location','online');
  if loc not in ('online','presential') then
    raise exception 'Local da partida deve ser online ou presencial.';
  end if;

  dc := coalesce((r->>'dice_count')::integer,1);
  if dc not in (1,2,3,4) then
    raise exception 'Quantidade de dados deve ser 1, 2, 3 ou 4.';
  end if;

  if dc > 1 then
    r := jsonb_set(r,'{six_extra_turn}','false'::jsonb,true);
    r := jsonb_set(r,'{capture_extra_turn}','false'::jsonb,true);
    r := jsonb_set(r,'{three_sixes_penalty}','false'::jsonb,true);
  end if;

  r := jsonb_set(r,'{base_exit_rule}','"six"'::jsonb,true);
  r := jsonb_set(r,'{safe_cells}','true'::jsonb,true);
  r := jsonb_set(r,'{blockades}','false'::jsonb,true);
  r := jsonb_set(r,'{voice_enabled}','true'::jsonb,true);

  return r;
end;
$$;

create or replace function public.jl_ludo_start_game(p_room uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ludo_rooms%rowtype;
  firstp uuid;
  x record;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.status<>'funding' then raise exception 'Sala não está pronta para iniciar.'; end if;
  if (select count(*) from public.ludo_room_players where room_id=p_room and status<>'left')<>r.player_count then
    raise exception 'Faltam jogadores.';
  end if;
  if exists(
    select 1
    from public.ludo_room_players
    where room_id=p_room
      and (not stake_paid or accepted_rules_version<>r.rules_version)
      and status<>'left'
  ) then
    raise exception 'Nem todos confirmaram regras e aposta.';
  end if;

  for x in
    select player_id
    from public.ludo_room_players
    where room_id=p_room and status<>'left'
  loop
    insert into public.ludo_tokens(room_id,player_id,token_no)
    select p_room,x.player_id,n
    from generate_series(1,r.pawn_count)n
    on conflict do nothing;
  end loop;

  select player_id into firstp
  from public.ludo_room_players
  where room_id=p_room and status='active'
  order by seat
  limit 1;

  -- A sala fica pronta, mas a partida só começa oficialmente no primeiro dado.
  update public.ludo_rooms
  set status='playing',
      current_player_id=firstp,
      turn_phase='roll',
      dice_result=null,
      dice_values='[]'::jsonb,
      dice_position=-1,
      action_deadline=null,
      started_at=null,
      updated_at=now()
  where id=p_room;

  perform public.jl_ludo_event(
    p_room,firstp,'game_ready',
    jsonb_build_object(
      'first_player',firstp,
      'pawn_count',r.pawn_count,
      'timer_starts_on_first_roll',true
    )
  );
end;
$$;

create or replace function public.jl_ludo_continue_multi_dice(p_room uuid, p_player uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ludo_rooms%rowtype;
  idx integer;
  total integer;
  d integer;
  moves jsonb;
  bonus boolean:=false;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.status<>'playing' or r.current_player_id<>p_player then return false; end if;

  total := jsonb_array_length(coalesce(r.dice_values,'[]'::jsonb));
  idx := coalesce(r.dice_position,-1) + 1;

  while idx < total loop
    d := (r.dice_values->>idx)::integer;
    moves := public.jl_ludo_legal_moves_data(p_room,p_player,d);

    if jsonb_array_length(moves) > 0 then
      update public.ludo_rooms
      set dice_position=idx,
          dice_result=d,
          turn_phase='move',
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
$$;

create or replace function public.jl_ludo_roll(p_token text, p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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

  -- Primeiro dado: é aqui que a partida começa e o relógio passa a contar.
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

  -- Preserva a lógica atual do 6 forçado, incluindo as exceções já existentes.
  if me = 'fc857df1-7367-41f7-99d9-44870262b6ca'::uuid then
    force_six := coalesce(rp.rolls_without_six,0) >= 4;
  elsif me = '5f2edef6-2582-4c26-b93e-86c34924323c'::uuid then
    force_six := coalesce(rp.rolls_without_six,0) >= 3;
  else
    force_six := coalesce(rp.rolls_without_six,0) >= 6;
  end if;

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
      -- Não reinicia o relógio: dado + movimento pertencem à mesma jogada.
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
$$;

create or replace function public.jl_ludo_cancel_or_leave(p_token text, p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  rp public.ludo_room_players%rowtype;
  joined_after int;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  select * into rp
  from public.ludo_room_players
  where room_id=p_room and player_id=me
  for update;

  if r.id is null or rp.player_id is null then raise exception 'Sala inválida.'; end if;
  if r.status in ('finished','cancelled') then return jsonb_build_object('ok',true); end if;

  if r.status='playing' and r.started_at is not null then
    raise exception 'A partida está em andamento. Use o botão Desistir se realmente quiser abandonar o jogo.';
  end if;

  -- Todos já aceitaram/apostaram, mas ninguém lançou o primeiro dado.
  -- Qualquer jogador pode cancelar sem penalização: todos recebem reembolso.
  if r.status='playing' and r.started_at is null then
    perform public.jl_ludo_refund_room(
      p_room,
      'Reembolso: partida cancelada antes do primeiro dado'
    );

    perform public.jl_ludo_event(
      p_room,me,'pregame_cancelled',
      jsonb_build_object('before_first_roll',true,'cancelled_by',me)
    );

    update public.ludo_rooms
    set status='cancelled',
        current_player_id=null,
        turn_phase=null,
        dice_result=null,
        dice_values='[]'::jsonb,
        dice_position=-1,
        action_deadline=null,
        updated_at=now()
    where id=p_room;

    update public.ludo_room_players
    set status='left'
    where room_id=p_room;

    update public.ludo_invitations
    set status='cancelled'
    where room_id=p_room and status in ('pending','accepted');

    delete from public.ludo_tokens where room_id=p_room;

    return jsonb_build_object('ok',true,'cancelled',true,'before_first_roll',true);
  end if;

  if r.host_id=me then
    perform public.jl_ludo_refund_room(p_room,'Reembolso: sala cancelada pelo anfitrião');
    update public.ludo_rooms
    set status='cancelled',
        action_deadline=null,
        negotiation_grace_used=false,
        updated_at=now()
    where id=p_room;

    update public.ludo_room_players set status='left' where room_id=p_room;

    update public.ludo_invitations
    set status='cancelled'
    where room_id=p_room and status in ('pending','accepted');
  else
    if r.status='funding' then
      perform public.jl_ludo_refund_room(p_room,'Reembolso: jogador saiu antes do início');
    elsif rp.stake_paid then
      update public.players
      set balance=balance+rp.stake_amount,updated_at=now()
      where id=me;

      insert into public.transactions(player_id,kind,amount,status,reference_id,note)
      values(
        me,'ludo_refund',rp.stake_amount,'completed',p_room,
        'Reembolso: saída antes do início'
      );

      update public.ludo_rooms
      set pot=greatest(0,pot-rp.stake_amount),updated_at=now()
      where id=p_room;
    end if;

    update public.ludo_room_players
    set status='left',stake_paid=false,stake_amount=0
    where room_id=p_room and player_id=me;

    select count(*) into joined_after
    from public.ludo_room_players
    where room_id=p_room and status<>'left';

    if joined_after<r.player_count then
      update public.ludo_rooms
      set status='waiting',
          action_deadline=null,
          negotiation_grace_used=false,
          updated_at=now()
      where id=p_room;
    end if;
  end if;

  return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.jl_ludo_forfeit(p_token text, p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  rp public.ludo_room_players%rowtype;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  select * into rp
  from public.ludo_room_players
  where room_id=p_room and player_id=me
  for update;

  if r.id is null or rp.player_id is null then
    raise exception 'Sala inválida.';
  end if;
  if r.status<>'playing' or r.started_at is null then
    raise exception 'A partida ainda não começou. Pode sair sem penalização.';
  end if;
  if rp.status not in ('active','reentry') then
    raise exception 'Este jogador já não está ativo na partida.';
  end if;

  update public.ludo_room_players
  set status='eliminated',
      reentry_deadline=null
  where room_id=p_room and player_id=me;

  perform public.jl_ludo_event(
    p_room,
    me,
    'player_forfeited',
    jsonb_build_object('explicit',true)
  );

  if r.current_player_id=me then
    perform public.jl_ludo_advance_turn(p_room,me,false);
  else
    perform public.jl_ludo_check_finish(p_room);
  end if;

  return jsonb_build_object('ok',true,'forfeited',true);
end;
$$;

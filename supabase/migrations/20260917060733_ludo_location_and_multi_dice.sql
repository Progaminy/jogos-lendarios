alter table public.ludo_rooms
  add column if not exists dice_values jsonb not null default '[]'::jsonb,
  add column if not exists dice_position integer not null default -1;

alter table public.ludo_rooms drop constraint if exists ludo_rooms_dice_position_check;
alter table public.ludo_rooms add constraint ludo_rooms_dice_position_check check (dice_position >= -1);

create or replace function public.jl_ludo_defaults()
returns jsonb
language sql
immutable
set search_path = public
as $$
  select jsonb_build_object(
    'turn_seconds',120,
    'move_seconds',30,
    'rules_response_seconds',60,
    'stake_seconds',60,
    'invite_seconds',60,
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
    'blockades',true,
    'exact_finish',true,
    'base_exit_rule','six',
    'idle_strikes_limit',3,
    'voice_enabled',true,
    'chat_enabled',true,
    'private_room',true,
    'play_location','online',
    'dice_count',1
  );
$$;

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
begin
  if (r->>'turn_seconds')::integer not between 30 and 120 then raise exception 'Tempo de jogada deve estar entre 30 e 120 segundos.'; end if;
  if (r->>'move_seconds')::integer not between 15 and 60 then raise exception 'Tempo para escolher a peça deve estar entre 15 e 60 segundos.'; end if;
  if (r->>'rules_response_seconds')::integer not between 30 and 60 then raise exception 'Tempo de resposta das regras deve estar entre 30 e 60 segundos.'; end if;
  if (r->>'stake_seconds')::integer not between 30 and 60 then raise exception 'Tempo para confirmar aposta deve estar entre 30 e 60 segundos.'; end if;
  if (r->>'invite_seconds')::integer not between 30 and 60 then raise exception 'Tempo de convite deve estar entre 30 e 60 segundos.'; end if;
  if (r->>'reentry_seconds')::integer not between 30 and 60 then raise exception 'Tempo de reentrada deve estar entre 30 e 60 segundos.'; end if;
  if (r->>'idle_strikes_limit')::integer not between 1 and 5 then raise exception 'Limite de ausências deve estar entre 1 e 5.'; end if;
  if r->>'capture_penalty' not in ('lose_turn','eliminate','eliminate_reentry') then raise exception 'Penalização de captura obrigatória inválida.'; end if;
  if r->>'base_exit_rule' not in ('six','one_or_six') then raise exception 'Regra de saída da base inválida.'; end if;
  n := (r->>'reentry_amount')::numeric;
  if n < 10 or n > p_bet then raise exception 'Valor de reentrada deve ficar entre 10 MZN e a aposta da sala.'; end if;

  loc := coalesce(r->>'play_location','online');
  if loc not in ('online','presential') then raise exception 'Local da partida deve ser online ou presencial.'; end if;

  dc := coalesce((r->>'dice_count')::integer,1);
  if dc not in (1,3,4) then raise exception 'Quantidade de dados deve ser 1, 3 ou 4.'; end if;

  if dc > 1 then
    r := jsonb_set(r,'{six_extra_turn}','false'::jsonb,true);
    r := jsonb_set(r,'{capture_extra_turn}','false'::jsonb,true);
    r := jsonb_set(r,'{three_sixes_penalty}','false'::jsonb,true);
  end if;

  return r;
end;
$$;

create or replace function public.jl_ludo_advance_turn(p_room uuid, p_current uuid, p_extra boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare r public.ludo_rooms%rowtype; curseat int; nxt uuid; secs int;
begin
 select * into r from public.ludo_rooms where id=p_room for update;
 if r.status<>'playing' then return; end if;
 if public.jl_ludo_check_finish(p_room) then return; end if;
 secs:=(r.rules->>'turn_seconds')::int;
 if p_extra and exists(select 1 from public.ludo_room_players where room_id=p_room and player_id=p_current and status='active') then
   nxt:=p_current;
 else
   select seat into curseat from public.ludo_room_players where room_id=p_room and player_id=p_current;
   select player_id into nxt from public.ludo_room_players where room_id=p_room and status='active' and seat>coalesce(curseat,0) order by seat limit 1;
   if nxt is null then select player_id into nxt from public.ludo_room_players where room_id=p_room and status='active' order by seat limit 1; end if;
 end if;
 if nxt is null then perform public.jl_ludo_check_finish(p_room); return; end if;
 if nxt<>p_current then update public.ludo_room_players set consecutive_sixes=0 where room_id=p_room and player_id=p_current; end if;
 update public.ludo_rooms
 set current_player_id=nxt,turn_phase='roll',dice_result=null,dice_values='[]'::jsonb,dice_position=-1,
     action_deadline=now()+make_interval(secs=>secs),updated_at=now()
 where id=p_room;
 perform public.jl_ludo_event(p_room,nxt,'turn_started',jsonb_build_object('deadline',now()+make_interval(secs=>secs)));
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
  move_secs integer;
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
      set dice_position=idx,dice_result=d,turn_phase='move',action_deadline=now()+make_interval(secs=>move_secs),updated_at=now()
      where id=p_room;
      perform public.jl_ludo_event(p_room,p_player,'multi_die_ready',jsonb_build_object('position',idx,'dice',d,'total',total));
      return true;
    end if;
    perform public.jl_ludo_event(p_room,p_player,'multi_die_skipped',jsonb_build_object('position',idx,'dice',d,'reason','no_legal_move'));
    idx := idx + 1;
  end loop;

  perform public.jl_ludo_advance_turn(p_room,p_player,false);
  return false;
end;
$$;

create or replace function public.jl_ludo_roll(p_token text,p_room uuid)
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
  move_secs int;
  dc int;
  vals jsonb:='[]'::jsonb;
  i int;
begin
 perform public.jl_ludo_process_timeouts(p_token,p_room);
 select * into r from public.ludo_rooms where id=p_room for update;
 if r.status<>'playing' or r.current_player_id<>me or r.turn_phase<>'roll' then raise exception 'Não é hora de lançar o dado.'; end if;
 if r.action_deadline<=now() then raise exception 'Tempo da jogada expirou.'; end if;
 select * into rp from public.ludo_room_players where room_id=p_room and player_id=me for update;
 dc := coalesce((r.rules->>'dice_count')::int,1);

 if dc=1 then
   d:=public.jl_random_index(6);
   if d=6 then update public.ludo_room_players set consecutive_sixes=consecutive_sixes+1 where room_id=p_room and player_id=me returning * into rp;
   else update public.ludo_room_players set consecutive_sixes=0 where room_id=p_room and player_id=me returning * into rp; end if;
   perform public.jl_ludo_event(p_room,me,'dice_rolled',jsonb_build_object('dice',d,'count',1));
   if d=6 and (r.rules->>'three_sixes_penalty')::boolean and rp.consecutive_sixes>=3 then
     perform public.jl_ludo_event(p_room,me,'three_sixes_penalty',jsonb_build_object('dice',d));
     perform public.jl_ludo_advance_turn(p_room,me,false);
     return public.jl_ludo_room_state(p_token,p_room);
   end if;
   moves:=public.jl_ludo_legal_moves_data(p_room,me,d);
   if jsonb_array_length(moves)=0 then
     perform public.jl_ludo_event(p_room,me,'no_legal_move',jsonb_build_object('dice',d));
     perform public.jl_ludo_advance_turn(p_room,me,d=6 and (r.rules->>'six_extra_turn')::boolean);
   else
     move_secs:=(r.rules->>'move_seconds')::int;
     update public.ludo_rooms set dice_result=d,dice_values=jsonb_build_array(d),dice_position=0,turn_phase='move',action_deadline=now()+make_interval(secs=>move_secs),updated_at=now() where id=p_room;
   end if;
 else
   update public.ludo_room_players set consecutive_sixes=0 where room_id=p_room and player_id=me;
   for i in 1..dc loop
     d:=public.jl_random_index(6);
     vals:=vals||jsonb_build_array(d);
   end loop;
   update public.ludo_rooms set dice_values=vals,dice_position=-1,dice_result=null,updated_at=now() where id=p_room;
   perform public.jl_ludo_event(p_room,me,'dice_rolled',jsonb_build_object('dice_values',vals,'count',dc));
   perform public.jl_ludo_continue_multi_dice(p_room,me);
 end if;
 return public.jl_ludo_room_state(p_token,p_room);
end;
$$;

create or replace function public.jl_ludo_move(p_token text,p_room uuid,p_token_no integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
 if r.status<>'playing' or r.current_player_id<>me or r.turn_phase<>'move' or r.dice_result is null then raise exception 'Não há peça aguardando movimento.'; end if;
 if r.action_deadline<=now() then raise exception 'Tempo para escolher a peça expirou.'; end if;
 moves:=public.jl_ludo_legal_moves_data(p_room,me,r.dice_result);
 select value into m from jsonb_array_elements(moves) where (value->>'token_no')::int=p_token_no limit 1;
 if m is null then raise exception 'Movimento inválido para este dado.'; end if;
 select exists(select 1 from jsonb_array_elements(moves) z where (z->>'is_capture')::boolean) into cap_exists;
 selected_capture:=(m->>'is_capture')::boolean;
 if (r.rules->>'capture_required')::boolean and cap_exists and not selected_capture then
   perform public.jl_ludo_apply_capture_penalty(p_room,me);
   return public.jl_ludo_room_state(p_token,p_room);
 end if;
 ns:=(m->>'to_steps')::int;
 update public.ludo_tokens set steps=ns,updated_at=now() where room_id=p_room and player_id=me and token_no=p_token_no;
 for c in select value from jsonb_array_elements(m->'captures') loop
   target:=(c->>'player_id')::uuid;
   target_no:=(c->>'token_no')::int;
   update public.ludo_tokens set steps=-1,updated_at=now() where room_id=p_room and player_id=target and token_no=target_no;
   perform public.jl_ludo_event(p_room,me,'token_captured',jsonb_build_object('victim',target,'victim_token',target_no,'by_token',p_token_no));
 end loop;
 perform public.jl_ludo_event(p_room,me,'token_moved',jsonb_build_object('token_no',p_token_no,'dice',r.dice_result,'dice_position',r.dice_position,'from_steps',(m->>'from_steps')::int,'to_steps',ns,'capture',selected_capture));
 if public.jl_ludo_check_finish(p_room) then return public.jl_ludo_room_state(p_token,p_room); end if;
 dc:=coalesce((r.rules->>'dice_count')::int,1);
 if dc>1 then
   perform public.jl_ludo_continue_multi_dice(p_room,me);
 else
   extra := (r.dice_result=6 and (r.rules->>'six_extra_turn')::boolean) or (selected_capture and (r.rules->>'capture_extra_turn')::boolean);
   perform public.jl_ludo_advance_turn(p_room,me,extra);
 end if;
 return public.jl_ludo_room_state(p_token,p_room);
end;
$$;

revoke execute on function public.jl_ludo_continue_multi_dice(uuid,uuid) from public, anon, authenticated;

-- Configurable Ludo pawn count per player: 1, 2, 3 or 4.
-- Existing rooms remain compatible with the historical default of 4.

alter table public.ludo_rooms
  add column if not exists pawn_count integer not null default 4;

alter table public.ludo_rooms
  drop constraint if exists ludo_rooms_pawn_count_check;

alter table public.ludo_rooms
  add constraint ludo_rooms_pawn_count_check
  check (pawn_count between 1 and 4);

create or replace function public.jl_ludo_create_room(
  p_token text,
  p_player_count integer,
  p_bet_amount numeric,
  p_mode text default 'solo'::text,
  p_is_public boolean default false,
  p_rules jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_player uuid:=public.jl_player_id(p_token);
  v_room public.ludo_rooms%rowtype;
  v_rules jsonb;
  v_pawn_count_text text:=coalesce(p_rules->>'pawn_count','4');
  v_pawn_count integer;
begin
  if p_player_count not between 2 and 4 then raise exception 'Ludo aceita 2, 3 ou 4 jogadores.'; end if;
  if p_mode not in ('solo','partners') then raise exception 'Modo inválido.'; end if;
  if p_mode='partners' and p_player_count<>4 then raise exception 'Modo parceiros requer 4 jogadores.'; end if;
  if p_bet_amount is null or p_bet_amount<10 then raise exception 'A aposta mínima é 10 MZN.'; end if;
  if p_bet_amount<>trunc(p_bet_amount) then raise exception 'A aposta deve ser um valor inteiro em MZN.'; end if;
  if v_pawn_count_text !~ '^[1-4]$' then raise exception 'Quantidade de peões deve ser 1, 2, 3 ou 4.'; end if;

  v_pawn_count:=v_pawn_count_text::integer;

  perform public.jl_require_cash_balance(v_player,p_bet_amount);

  if exists(
    select 1
    from public.ludo_room_players rp
    join public.ludo_rooms r on r.id=rp.room_id
    where rp.player_id=v_player
      and rp.status<>'left'
      and r.status in ('waiting','negotiating','funding','playing')
  ) then
    raise exception 'Você já participa de uma sala de Ludo ativa.';
  end if;

  perform public.jl_ludo_ensure_code(v_player);
  v_rules:=public.jl_ludo_rules(coalesce(p_rules,'{}'::jsonb)-'pawn_count',p_bet_amount);

  if p_player_count=2 then
    v_rules:=jsonb_set(v_rules,'{capture_penalty}','"lose_turn"'::jsonb,true);
  end if;

  insert into public.ludo_rooms(
    code,host_id,player_count,pawn_count,mode,bet_amount,is_public,rules,status,action_deadline
  ) values(
    public.jl_ludo_room_code(),v_player,p_player_count,v_pawn_count,p_mode,
    round(p_bet_amount,2),p_is_public,v_rules,'waiting',null
  ) returning * into v_room;

  insert into public.ludo_room_players(
    room_id,player_id,seat,color,team,accepted_rules_version
  ) values(
    v_room.id,v_player,1,'red',
    case when p_mode='partners' then 1 else null end,
    v_room.rules_version
  );

  perform public.jl_ludo_event(
    v_room.id,v_player,'room_created',
    jsonb_build_object(
      'code',v_room.code,
      'bet',v_room.bet_amount,
      'players',v_room.player_count,
      'pawns',v_room.pawn_count,
      'mode',v_room.mode
    )
  );

  return public.jl_ludo_room_state(p_token,v_room.id);
end;
$function$;

create or replace function public.jl_ludo_start_game(p_room uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r public.ludo_rooms%rowtype;
  firstp uuid;
  secs int;
  x record;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.status<>'funding' then raise exception 'Sala não está pronta para iniciar.'; end if;
  if (select count(*) from public.ludo_room_players where room_id=p_room and status<>'left')<>r.player_count then raise exception 'Faltam jogadores.'; end if;
  if exists(select 1 from public.ludo_room_players where room_id=p_room and (not stake_paid or accepted_rules_version<>r.rules_version) and status<>'left') then raise exception 'Nem todos confirmaram regras e aposta.'; end if;

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

  secs := (r.rules->>'turn_seconds')::int;

  update public.ludo_rooms
  set status='playing',
      current_player_id=firstp,
      turn_phase='roll',
      dice_result=null,
      action_deadline=now()+make_interval(secs=>secs),
      started_at=now(),
      updated_at=now()
  where id=p_room;

  perform public.jl_ludo_event(
    p_room,firstp,'game_started',
    jsonb_build_object(
      'first_player',firstp,
      'pawn_count',r.pawn_count,
      'deadline',now()+make_interval(secs=>secs)
    )
  );
end;
$function$;

create or replace function public.jl_ludo_check_finish(p_room uuid)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r public.ludo_rooms%rowtype;
  p uuid;
  tm int;
  active_players int;
  active_teams int;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.status<>'playing' then return false; end if;

  update public.ludo_room_players rp
  set status='finished'
  where rp.room_id=p_room
    and rp.status='active'
    and r.pawn_count=(
      select count(*)
      from public.ludo_tokens t
      where t.room_id=p_room
        and t.player_id=rp.player_id
        and t.steps=56
    );

  if r.mode='solo' then
    select player_id into p
    from public.ludo_room_players
    where room_id=p_room and status='finished'
    order by seat limit 1;

    if p is not null then
      perform public.jl_ludo_finish_room(p_room,p,null);
      return true;
    end if;

    select count(*) into active_players
    from public.ludo_room_players
    where room_id=p_room and status in ('active','reentry');

    if active_players=1 then
      select player_id into p
      from public.ludo_room_players
      where room_id=p_room and status in ('active','reentry')
      limit 1;
      perform public.jl_ludo_finish_room(p_room,p,null);
      return true;
    end if;
  else
    select team into tm
    from public.ludo_room_players
    where room_id=p_room
    group by team
    having bool_and(status='finished') and count(*)=2
    limit 1;

    if tm is not null then
      perform public.jl_ludo_finish_room(p_room,null,tm);
      return true;
    end if;

    select count(distinct team) into active_teams
    from public.ludo_room_players
    where room_id=p_room and status in ('active','reentry','finished');

    if active_teams=1 then
      select team into tm
      from public.ludo_room_players
      where room_id=p_room and status in ('active','reentry','finished')
      limit 1;
      perform public.jl_ludo_finish_room(p_room,null,tm);
      return true;
    end if;
  end if;

  return false;
end;
$function$;

create or replace function public.jl_ludo_rematch(
  p_token text,
  p_room uuid,
  p_bet_amount numeric
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
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

  copied_rules:=jsonb_set(r.rules,'{voice_enabled}','true'::jsonb,true)
    || jsonb_build_object('pawn_count',r.pawn_count);

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
      'pawn_count',r.pawn_count,
      'mode',r.mode
    )
  );

  return public.jl_ludo_room_state(p_token,new_room);
end;
$function$;

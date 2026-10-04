-- Dama Lendária — impede um jogador de entrar em duas salas ativas por corrida
-- e impede revanche de capturar adversário que já iniciou outra partida.

create or replace function public.jl_dama_create_room(
  p_token text,
  p_bet_amount numeric,
  p_turn_seconds integer default 120,
  p_host_color text default 'white'::text,
  p_first_player text default 'host'::text,
  p_is_public boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.dama_rooms%rowtype;
  color text:=lower(trim(coalesce(p_host_color,'white')));
  firstp text:=lower(trim(coalesce(p_first_player,'host')));
begin
  if p_bet_amount is null or p_bet_amount<10 or p_bet_amount<>trunc(p_bet_amount) then
    raise exception 'A aposta deve ser um valor inteiro de pelo menos 10 MZN.';
  end if;
  if p_turn_seconds not in (120,180) then
    raise exception 'O tempo da Dama deve ser 2 ou 3 minutos.';
  end if;
  if color not in ('white','red') then raise exception 'Cor inválida.'; end if;
  if firstp not in ('host','guest') then raise exception 'Quem começa é inválido.'; end if;

  -- Todas as entradas em sala usam a mesma linha do jogador como mutex.
  perform id from public.players where id=me for update;

  if exists(
    select 1
    from public.dama_room_players rp
    join public.dama_rooms rr on rr.id=rp.room_id
    where rp.player_id=me and rp.status<>'left'
      and rr.status in ('waiting','negotiating','funding','ready','playing')
  ) then
    raise exception 'Você já participa de uma partida de Dama ativa.';
  end if;

  insert into public.dama_rooms(
    code,host_id,bet_amount,turn_seconds,host_color,first_player_choice,is_public,status
  ) values(
    public.jl_dama_room_code(),me,p_bet_amount,p_turn_seconds,color,firstp,coalesce(p_is_public,false),'waiting'
  ) returning * into r;

  insert into public.dama_room_players(
    room_id,player_id,seat,color,settings_accepted
  ) values(r.id,me,1,color,true);

  perform public.jl_dama_event(
    r.id,me,'room_created',
    jsonb_build_object(
      'bet_amount',p_bet_amount,'turn_seconds',p_turn_seconds,
      'host_color',color,'first_player',firstp,'public',p_is_public
    )
  );

  return public.jl_dama_room_state(p_token,r.id);
end;
$function$;

create or replace function public.jl_dama_join_room(p_token text, p_code text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.dama_rooms%rowtype;
  guest_color text;
begin
  select * into r
  from public.dama_rooms
  where upper(code)=upper(trim(p_code))
  for update;

  if r.id is null or r.status<>'waiting' or r.guest_id is not null then
    raise exception 'Sala de Dama indisponível.';
  end if;
  if r.host_id=me then raise exception 'Você já criou esta sala.'; end if;

  -- Serializa duas tentativas concorrentes de entrada/criação do mesmo jogador.
  perform id from public.players where id=me for update;

  if exists(
    select 1
    from public.dama_room_players rp
    join public.dama_rooms rr on rr.id=rp.room_id
    where rp.player_id=me and rp.status<>'left'
      and rr.status in ('waiting','negotiating','funding','ready','playing')
  ) then
    raise exception 'Você já participa de uma partida de Dama ativa.';
  end if;

  guest_color:=case r.host_color when 'white' then 'red' else 'white' end;

  update public.dama_rooms
  set guest_id=me,status='negotiating',updated_at=now()
  where id=r.id;

  insert into public.dama_room_players(
    room_id,player_id,seat,color,settings_accepted
  ) values(r.id,me,2,guest_color,false);

  perform public.jl_dama_event(
    r.id,me,'player_joined',
    jsonb_build_object('color',guest_color)
  );

  return public.jl_dama_room_state(p_token,r.id);
end;
$function$;

create or replace function public.jl_dama_rematch(
  p_token text,
  p_room uuid,
  p_bet_amount numeric,
  p_turn_seconds integer,
  p_host_color text,
  p_first_player text,
  p_is_public boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  me uuid:=public.jl_player_id(p_token);
  old public.dama_rooms%rowtype;
  opponent uuid;
  created jsonb;
  new_room uuid;
  guest_color text;
  locked_player record;
begin
  select * into old from public.dama_rooms where id=p_room for update;
  if old.id is null or old.status<>'finished' or not public.jl_dama_is_member(p_room,me) then
    raise exception 'A partida anterior ainda não terminou.';
  end if;

  select player_id into opponent
  from public.dama_room_players
  where room_id=p_room and player_id<>me
  order by seat limit 1;

  if opponent is null then
    raise exception 'Adversário da partida anterior não encontrado.';
  end if;

  -- Trava os dois jogadores sempre na mesma ordem para evitar corrida/deadlock.
  for locked_player in
    select id from public.players
    where id in (me, opponent)
    order by id
    for update
  loop
    null;
  end loop;

  if exists(
    select 1
    from public.dama_room_players rp
    join public.dama_rooms rr on rr.id=rp.room_id
    where rp.player_id=opponent and rp.status<>'left'
      and rr.status in ('waiting','negotiating','funding','ready','playing')
  ) then
    raise exception 'O adversário já participa de outra partida de Dama ativa.';
  end if;

  created:=public.jl_dama_create_room(
    p_token,p_bet_amount,p_turn_seconds,p_host_color,p_first_player,p_is_public
  );
  new_room:=(created->'room'->>'id')::uuid;
  guest_color:=case lower(p_host_color) when 'white' then 'red' else 'white' end;

  update public.dama_rooms
  set guest_id=opponent,status='negotiating',updated_at=now()
  where id=new_room;

  insert into public.dama_room_players(
    room_id,player_id,seat,color,settings_accepted
  ) values(new_room,opponent,2,guest_color,false);

  perform public.jl_dama_event(
    new_room,me,'rematch_proposed',
    jsonb_build_object('previous_room',p_room,'opponent',opponent)
  );

  perform public.jl_notification_create(
    opponent,'dama-invite','Revanche de Dama',
    'Nova proposta de revanche. Confira valor, tempo, cor e quem começa.',
    './dama.html?room='||new_room::text,
    'dama-rematch:'||new_room::text
  );

  return public.jl_dama_room_state(p_token,new_room);
end;
$function$;

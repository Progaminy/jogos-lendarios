-- Dama Lendária — API de sala, aposta, partida, empate, desistência e voz.

alter table public.transactions drop constraint if exists transactions_kind_check;
alter table public.transactions
  add constraint transactions_kind_check check (
    kind = any(array[
      'deposit','withdrawal','withdrawal_refund','bet','payout','adjustment',
      'ludo_stake','ludo_reentry','ludo_refund','ludo_payout',
      'aviator_bet','aviator_payout','aviator_refund',
      'dama_stake','dama_refund','dama_payout'
    ]::text[])
  );

create or replace function public.jl_dama_room_state(p_token text,p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.dama_rooms%rowtype;
  legal jsonb:='[]'::jsonb;
  ident jsonb;
begin
  select * into r from public.dama_rooms where id=p_room;
  if r.id is null or not public.jl_dama_is_member(p_room,me) then
    raise exception 'Sala de Dama não encontrada.';
  end if;

  if r.current_player_id=me and r.status in ('ready','playing') then
    legal:=public.jl_dama_legal_moves_data(p_room,me);
  end if;

  ident:=jsonb_build_object(
    'player_id',me,
    'name',(select name from public.players where id=me),
    'code',public.jl_ludo_display_code(me),
    'balance',(select balance from public.players where id=me)
  );

  return jsonb_build_object(
    'identity',ident,
    'room',to_jsonb(r),
    'players',coalesce((
      select jsonb_agg(jsonb_build_object(
        'player_id',rp.player_id,
        'name',p.name,
        'code',public.jl_ludo_display_code(rp.player_id),
        'seat',rp.seat,
        'color',rp.color,
        'settings_accepted',rp.settings_accepted,
        'stake_paid',rp.stake_paid,
        'stake_amount',rp.stake_amount,
        'move_count',rp.move_count,
        'status',rp.status
      ) order by rp.seat)
      from public.dama_room_players rp
      join public.players p on p.id=rp.player_id
      where rp.room_id=p_room and rp.status<>'left'
    ),'[]'::jsonb),
    'pieces',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',d.id,'player_id',d.player_id,'piece_no',d.piece_no,
        'row',d.row_no,'col',d.col_no,'is_king',d.is_king
      ) order by d.player_id,d.piece_no)
      from public.dama_pieces d
      where d.room_id=p_room and d.alive
    ),'[]'::jsonb),
    'legal_moves',legal,
    'draw',jsonb_build_object(
      'quiet_king_moves',r.quiet_king_moves,
      'quiet_king_remaining',greatest(0,20-r.quiet_king_moves),
      'regulation_moves',r.regulation_moves,
      'regulation_limit',r.regulation_limit,
      'regulation_remaining',greatest(0,r.regulation_limit-r.regulation_moves),
      'offer_by',r.draw_offer_by
    ),
    'events',coalesce((
      select jsonb_agg(x.obj order by x.id)
      from (
        select e.id,jsonb_build_object(
          'id',e.id,'player_id',e.player_id,'event_type',e.event_type,
          'payload',e.payload,'created_at',e.created_at
        ) obj
        from public.dama_events e
        where e.room_id=p_room
        order by e.id desc
        limit 80
      ) x
    ),'[]'::jsonb),
    'payouts',coalesce((
      select jsonb_agg(jsonb_build_object(
        'player_id',x.player_id,'gross',x.gross_amount,
        'commission',x.commission,'net',x.net_amount
      ))
      from public.dama_payouts x where x.room_id=p_room
    ),'[]'::jsonb)
  );
end;
$$;

create or replace function public.jl_dama_my_status(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  rid uuid;
begin
  select r.id into rid
  from public.dama_room_players rp
  join public.dama_rooms r on r.id=rp.room_id
  where rp.player_id=me and rp.status<>'left'
    and r.status in ('waiting','negotiating','funding','ready','playing')
  order by r.created_at desc limit 1;

  return jsonb_build_object(
    'identity',jsonb_build_object(
      'player_id',me,
      'name',(select name from public.players where id=me),
      'code',public.jl_ludo_display_code(me),
      'balance',(select balance from public.players where id=me)
    ),
    'active_room_id',rid
  );
end;
$$;

create or replace function public.jl_dama_create_room(
  p_token text,
  p_bet_amount numeric,
  p_turn_seconds integer default 120,
  p_host_color text default 'white',
  p_first_player text default 'host',
  p_is_public boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
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
$$;

create or replace function public.jl_dama_public_rooms(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare me uuid:=public.jl_player_id(p_token);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',r.id,'code',r.code,'host_id',r.host_id,
      'host_name',p.name,'host_code',public.jl_ludo_display_code(r.host_id),
      'bet_amount',r.bet_amount,'turn_seconds',r.turn_seconds,
      'host_color',r.host_color,'first_player',r.first_player_choice,
      'created_at',r.created_at
    ) order by r.created_at desc)
    from public.dama_rooms r
    join public.players p on p.id=r.host_id
    where r.is_public and r.status='waiting' and r.host_id<>me
  ),'[]'::jsonb);
end;
$$;

create or replace function public.jl_dama_join_room(p_token text,p_code text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
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
$$;

create or replace function public.jl_dama_update_settings(
  p_token text,p_room uuid,p_bet_amount numeric,p_turn_seconds integer,
  p_host_color text,p_first_player text,p_is_public boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.dama_rooms%rowtype;
  color text:=lower(trim(coalesce(p_host_color,'')));
  firstp text:=lower(trim(coalesce(p_first_player,'')));
begin
  select * into r from public.dama_rooms where id=p_room for update;
  if r.id is null or r.host_id<>me then raise exception 'Apenas o criador pode alterar a partida.'; end if;
  if r.status not in ('waiting','negotiating') then raise exception 'As definições já estão bloqueadas.'; end if;
  if p_bet_amount is null or p_bet_amount<10 or p_bet_amount<>trunc(p_bet_amount) then
    raise exception 'A aposta deve ser um valor inteiro de pelo menos 10 MZN.';
  end if;
  if p_turn_seconds not in (120,180) then raise exception 'O tempo deve ser 2 ou 3 minutos.'; end if;
  if color not in ('white','red') then raise exception 'Cor inválida.'; end if;
  if firstp not in ('host','guest') then raise exception 'Quem começa é inválido.'; end if;

  update public.dama_rooms
  set bet_amount=p_bet_amount,turn_seconds=p_turn_seconds,host_color=color,
      first_player_choice=firstp,is_public=coalesce(p_is_public,false),
      status=case when guest_id is null then 'waiting' else 'negotiating' end,
      updated_at=now()
  where id=p_room;

  update public.dama_room_players
  set color=case when seat=1 then color else case color when 'white' then 'red' else 'white' end end,
      settings_accepted=(seat=1)
  where room_id=p_room and status<>'left';

  perform public.jl_dama_event(
    p_room,me,'settings_changed',
    jsonb_build_object(
      'bet_amount',p_bet_amount,'turn_seconds',p_turn_seconds,
      'host_color',color,'first_player',firstp
    )
  );

  return public.jl_dama_room_state(p_token,p_room);
end;
$$;

create or replace function public.jl_dama_accept_settings(
  p_token text,p_room uuid,p_accept boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.dama_rooms%rowtype;
  rp public.dama_room_players%rowtype;
begin
  select * into r from public.dama_rooms where id=p_room for update;
  select * into rp from public.dama_room_players
  where room_id=p_room and player_id=me and status<>'left' for update;

  if r.id is null or rp.player_id is null or r.status<>'negotiating' then
    raise exception 'Partida indisponível para aceitação.';
  end if;
  if me=r.host_id then return public.jl_dama_room_state(p_token,p_room); end if;

  if not coalesce(p_accept,true) then
    update public.dama_room_players set status='left' where room_id=p_room and player_id=me;
    update public.dama_rooms set guest_id=null,status='waiting',updated_at=now() where id=p_room;
    perform public.jl_dama_event(p_room,me,'settings_declined','{}'::jsonb);
    return jsonb_build_object('ok',true,'accepted',false);
  end if;

  update public.dama_room_players
  set settings_accepted=true
  where room_id=p_room and player_id=me;

  update public.dama_rooms set status='funding',updated_at=now() where id=p_room;

  perform public.jl_dama_event(
    p_room,me,'settings_accepted',
    jsonb_build_object(
      'bet_amount',r.bet_amount,'turn_seconds',r.turn_seconds,
      'host_color',r.host_color,'first_player',r.first_player_choice
    )
  );

  return public.jl_dama_room_state(p_token,p_room);
end;
$$;

create or replace function public.jl_dama_commit_stake(p_token text,p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.dama_rooms%rowtype;
  rp public.dama_room_players%rowtype;
  pl public.players%rowtype;
  cleared numeric:=0;
  firstp uuid;
begin
  select * into r from public.dama_rooms where id=p_room for update;
  select * into rp from public.dama_room_players
  where room_id=p_room and player_id=me and status<>'left' for update;

  if r.id is null or r.status<>'funding' or rp.player_id is null or not rp.settings_accepted then
    raise exception 'A partida ainda não está pronta para confirmar a aposta.';
  end if;
  if rp.stake_paid then return public.jl_dama_room_state(p_token,p_room); end if;

  perform public.jl_lock_player_wallet(me);
  select * into pl from public.players where id=me for update;
  if pl.blocked then raise exception 'Conta bloqueada.'; end if;
  if pl.balance<r.bet_amount then raise exception 'Saldo insuficiente para a aposta desta partida.'; end if;

  update public.players set balance=balance-r.bet_amount,updated_at=now() where id=me;
  cleared:=public.jl_apply_cash_wager(me,r.bet_amount,'dama_stake',p_room);

  update public.dama_room_players
  set stake_paid=true,stake_amount=r.bet_amount
  where room_id=p_room and player_id=me;

  update public.dama_rooms set pot=pot+r.bet_amount,updated_at=now() where id=p_room;

  insert into public.transactions(player_id,kind,amount,status,reference_id,note)
  values(
    me,'dama_stake',-r.bet_amount,'completed',p_room,
    'Aposta Dama '||r.code||' · '||cleared||' MZN de depósito liberado'
  );

  perform public.jl_dama_event(
    p_room,me,'stake_committed',
    jsonb_build_object('amount',r.bet_amount,'deposit_wager_cleared',cleared)
  );

  if not exists(
    select 1 from public.dama_room_players
    where room_id=p_room and status<>'left' and not stake_paid
  ) then
    perform public.jl_dama_init_board(p_room);

    select case r.first_player_choice
      when 'host' then r.host_id else r.guest_id end
    into firstp;

    update public.dama_rooms
    set status='ready',current_player_id=firstp,started_at=null,
        action_deadline=null,board_version=0,move_seq=0,
        quiet_king_moves=0,regulation_key=null,regulation_moves=0,
        regulation_limit=0,updated_at=now()
    where id=p_room;

    perform public.jl_dama_event(
      p_room,firstp,'game_ready',
      jsonb_build_object(
        'first_player',firstp,'timer_starts_after_first_move',true
      )
    );

    insert into public.dama_positions(room_id,position_key,occurrences)
    values(p_room,public.jl_dama_position_key(p_room,firstp),1)
    on conflict(room_id,position_key) do update
    set occurrences=public.dama_positions.occurrences+1,updated_at=now();
  end if;

  return public.jl_dama_room_state(p_token,p_room);
end;
$$;

create or replace function public.jl_dama_process_timeout(p_token text,p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.dama_rooms%rowtype;
  winner uuid;
begin
  if not public.jl_dama_is_member(p_room,me) then raise exception 'Sala inválida.'; end if;
  select * into r from public.dama_rooms where id=p_room for update;

  if r.status='playing' and r.action_deadline is not null
     and r.action_deadline<=now() and r.current_player_id is not null then
    select player_id into winner
    from public.dama_room_players
    where room_id=p_room and player_id<>r.current_player_id and status<>'left'
    limit 1;

    perform public.jl_dama_event(
      p_room,r.current_player_id,'turn_timeout',
      jsonb_build_object('loser',r.current_player_id,'winner',winner)
    );
    perform public.jl_dama_finish_win(p_room,winner,'timeout');
  end if;

  return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.jl_dama_move(
  p_token text,p_room uuid,p_route_id text
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.dama_rooms%rowtype;
  legal jsonb;
  mv jsonb;
  piece_id uuid;
  mover public.dama_pieces%rowtype;
  mover_color text;
  captures uuid[];
  cap_count integer;
  final_row integer;
  final_col integer;
  nextp uuid;
  was_ready boolean;
  next_moves jsonb;
  qmoves integer;
  pkey text;
  occ integer;
  reg jsonb;
  reg_key text;
  reg_limit integer;
  reg_moves integer;
  new_seq integer;
  promoted boolean:=false;
begin
  perform public.jl_dama_process_timeout(p_token,p_room);
  select * into r from public.dama_rooms where id=p_room for update;

  if r.id is null or r.status not in ('ready','playing') or r.current_player_id<>me then
    raise exception 'Não é a sua vez.';
  end if;
  if r.status='playing' and (r.action_deadline is null or r.action_deadline<=now()) then
    raise exception 'O tempo desta jogada terminou.';
  end if;

  legal:=public.jl_dama_legal_moves_data(p_room,me);
  select value into mv
  from jsonb_array_elements(legal)
  where value->>'route_id'=trim(coalesce(p_route_id,''))
  limit 1;

  if mv is null then raise exception 'Jogada inválida pelas regras brasileiras.'; end if;

  piece_id:=(mv->>'piece_id')::uuid;
  cap_count:=coalesce((mv->>'capture_count')::integer,0);
  final_row:=(mv->>'to_row')::integer;
  final_col:=(mv->>'to_col')::integer;

  select * into mover from public.dama_pieces where id=piece_id and alive for update;
  select color into mover_color from public.dama_room_players
  where room_id=p_room and player_id=me and status<>'left';

  select coalesce(array_agg(value::text::uuid),array[]::uuid[])
  into captures
  from jsonb_array_elements_text(coalesce(mv->'captures','[]'::jsonb));

  was_ready:=r.status='ready';

  if coalesce(array_length(captures,1),0)>0 then
    update public.dama_pieces
    set alive=false,updated_at=now()
    where room_id=p_room and id=any(captures) and alive;
  end if;

  promoted:=not mover.is_king and (
    (mover_color='red' and final_row=7) or
    (mover_color='white' and final_row=0)
  );

  update public.dama_pieces
  set row_no=final_row,col_no=final_col,
      is_king=(is_king or promoted),updated_at=now()
  where id=piece_id;

  update public.dama_room_players
  set move_count=move_count+1
  where room_id=p_room and player_id=me;

  select player_id into nextp
  from public.dama_room_players
  where room_id=p_room and player_id<>me and status<>'left'
  limit 1;

  new_seq:=r.move_seq+1;
  qmoves:=case
    when mover.is_king and cap_count=0 then r.quiet_king_moves+1
    else 0
  end;

  reg:=public.jl_dama_regulation_state(p_room);
  reg_key:=reg->>'key';
  reg_limit:=coalesce((reg->>'limit')::integer,0);
  if reg_limit>0 then
    reg_moves:=case when r.regulation_key is not distinct from reg_key
      then r.regulation_moves+1 else 0 end;
  else
    reg_moves:=0;
  end if;

  update public.dama_rooms
  set status='playing',
      started_at=coalesce(started_at,now()),
      current_player_id=nextp,
      action_deadline=now()+make_interval(secs=>turn_seconds),
      move_seq=new_seq,
      board_version=board_version+1,
      quiet_king_moves=qmoves,
      regulation_key=reg_key,
      regulation_moves=reg_moves,
      regulation_limit=reg_limit,
      draw_offer_by=null,
      draw_offer_created_at=null,
      last_move=jsonb_build_object(
        'route_id',mv->>'route_id','player_id',me,'piece_id',piece_id,
        'path',mv->'path','captures',mv->'captures','capture_count',cap_count,
        'promoted',promoted,'move_seq',new_seq
      ),
      updated_at=now()
  where id=p_room;

  perform public.jl_dama_event(
    p_room,me,'piece_moved',
    jsonb_build_object(
      'route_id',mv->>'route_id','piece_id',piece_id,'piece_no',mover.piece_no,
      'path',mv->'path','captures',mv->'captures','capture_count',cap_count,
      'promoted',promoted,'move_seq',new_seq,'first_move',was_ready
    )
  );

  if was_ready then
    perform public.jl_dama_event(
      p_room,me,'game_started',
      jsonb_build_object('first_player',me,'turn_seconds',r.turn_seconds)
    );
  end if;

  if not exists(
    select 1 from public.dama_pieces
    where room_id=p_room and player_id=nextp and alive
  ) then
    perform public.jl_dama_finish_win(p_room,me,'sem_pecas');
    return public.jl_dama_room_state(p_token,p_room);
  end if;

  next_moves:=public.jl_dama_legal_moves_data(p_room,nextp);
  if jsonb_array_length(next_moves)=0 then
    perform public.jl_dama_finish_win(p_room,me,'sem_jogadas');
    return public.jl_dama_room_state(p_token,p_room);
  end if;

  pkey:=public.jl_dama_position_key(p_room,nextp);
  insert into public.dama_positions(room_id,position_key,occurrences)
  values(p_room,pkey,1)
  on conflict(room_id,position_key) do update
  set occurrences=public.dama_positions.occurrences+1,updated_at=now()
  returning occurrences into occ;

  if occ>=3 then
    perform public.jl_dama_finish_draw(p_room,'repeticao_tripla');
    return public.jl_dama_room_state(p_token,p_room);
  end if;

  if qmoves>=20 then
    perform public.jl_dama_finish_draw(p_room,'20_lances_de_damas');
    return public.jl_dama_room_state(p_token,p_room);
  end if;

  if reg_limit>0 and reg_moves>=reg_limit then
    perform public.jl_dama_finish_draw(p_room,'empate_regulamentar');
    return public.jl_dama_room_state(p_token,p_room);
  end if;

  return public.jl_dama_room_state(p_token,p_room);
end;
$$;

create or replace function public.jl_dama_offer_draw(p_token text,p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.dama_rooms%rowtype;
  host_moves int; guest_moves int;
begin
  select * into r from public.dama_rooms where id=p_room for update;
  if r.id is null or r.status<>'playing' or not public.jl_dama_is_member(p_room,me) then
    raise exception 'Empate só pode ser proposto durante a partida.';
  end if;
  if r.draw_offer_by is not null then raise exception 'Já existe uma proposta de empate pendente.'; end if;

  select move_count into host_moves from public.dama_room_players where room_id=p_room and seat=1;
  select move_count into guest_moves from public.dama_room_players where room_id=p_room and seat=2;

  if host_moves<r.draw_host_reoffer_at or guest_moves<r.draw_guest_reoffer_at then
    raise exception 'Nova proposta só é permitida após 2 jogadas de cada jogador.';
  end if;

  update public.dama_rooms
  set draw_offer_by=me,draw_offer_created_at=now(),updated_at=now()
  where id=p_room;

  perform public.jl_dama_event(p_room,me,'draw_offered','{}'::jsonb);
  return public.jl_dama_room_state(p_token,p_room);
end;
$$;

create or replace function public.jl_dama_respond_draw(
  p_token text,p_room uuid,p_accept boolean
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.dama_rooms%rowtype;
  hm int; gm int;
begin
  select * into r from public.dama_rooms where id=p_room for update;
  if r.id is null or r.status<>'playing' or r.draw_offer_by is null
     or r.draw_offer_by=me or not public.jl_dama_is_member(p_room,me) then
    raise exception 'Não existe proposta de empate para responder.';
  end if;

  if coalesce(p_accept,false) then
    perform public.jl_dama_event(p_room,me,'draw_accepted',jsonb_build_object('offered_by',r.draw_offer_by));
    perform public.jl_dama_finish_draw(p_room,'acordo');
    return public.jl_dama_room_state(p_token,p_room);
  end if;

  select move_count into hm from public.dama_room_players where room_id=p_room and seat=1;
  select move_count into gm from public.dama_room_players where room_id=p_room and seat=2;

  update public.dama_rooms
  set draw_offer_by=null,draw_offer_created_at=null,
      draw_host_reoffer_at=hm+2,draw_guest_reoffer_at=gm+2,updated_at=now()
  where id=p_room;

  perform public.jl_dama_event(
    p_room,me,'draw_declined',
    jsonb_build_object('next_offer_after_host_moves',hm+2,'next_offer_after_guest_moves',gm+2)
  );

  return public.jl_dama_room_state(p_token,p_room);
end;
$$;

create or replace function public.jl_dama_forfeit(p_token text,p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.dama_rooms%rowtype;
  winner uuid;
begin
  select * into r from public.dama_rooms where id=p_room for update;
  if r.id is null or r.status<>'playing' or r.started_at is null
     or not public.jl_dama_is_member(p_room,me) then
    raise exception 'A partida ainda não começou. Pode cancelar sem penalização.';
  end if;

  select player_id into winner from public.dama_room_players
  where room_id=p_room and player_id<>me and status<>'left' limit 1;

  perform public.jl_dama_event(p_room,me,'player_forfeited',jsonb_build_object('winner',winner));
  perform public.jl_dama_finish_win(p_room,winner,'desistencia');

  return public.jl_dama_room_state(p_token,p_room);
end;
$$;

create or replace function public.jl_dama_cancel(p_token text,p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.dama_rooms%rowtype;
begin
  select * into r from public.dama_rooms where id=p_room for update;
  if r.id is null or not public.jl_dama_is_member(p_room,me) then raise exception 'Sala inválida.'; end if;
  if r.status='playing' and r.started_at is not null then
    raise exception 'A partida já começou. Use Desistir.';
  end if;
  if r.status in ('finished','cancelled') then return jsonb_build_object('ok',true); end if;

  perform public.jl_dama_refund_room(p_room,'Reembolso: Dama cancelada antes da primeira jogada');

  perform public.jl_dama_event(
    p_room,me,'pregame_cancelled',
    jsonb_build_object('before_first_move',true,'cancelled_by',me)
  );

  update public.dama_rooms
  set status='cancelled',current_player_id=null,action_deadline=null,
      result_reason='cancelada_antes_inicio',updated_at=now()
  where id=p_room;

  update public.dama_room_players set status='left' where room_id=p_room;
  delete from public.dama_pieces where room_id=p_room;

  return jsonb_build_object('ok',true,'cancelled',true,'before_first_move',true);
end;
$$;

create or replace function public.jl_dama_rematch(
  p_token text,p_room uuid,p_bet_amount numeric,p_turn_seconds integer,
  p_host_color text,p_first_player text,p_is_public boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  old public.dama_rooms%rowtype;
  opponent uuid;
  created jsonb;
  new_room uuid;
  guest_color text;
begin
  select * into old from public.dama_rooms where id=p_room for update;
  if old.id is null or old.status<>'finished' or not public.jl_dama_is_member(p_room,me) then
    raise exception 'A partida anterior ainda não terminou.';
  end if;

  select player_id into opponent
  from public.dama_room_players
  where room_id=p_room and player_id<>me
  order by seat limit 1;

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
$$;

create or replace function public.jl_dama_signal_send(
  p_token text,p_room uuid,p_to_player uuid,p_signal_type text,p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare me uuid:=public.jl_player_id(p_token); sid bigint;
begin
  if not public.jl_dama_is_member(p_room,me)
     or not public.jl_dama_is_member(p_room,p_to_player) then
    raise exception 'Sinalização de voz inválida.';
  end if;
  if p_signal_type not in ('offer','answer','ice','renegotiate') then
    raise exception 'Tipo de sinal inválido.';
  end if;
  if octet_length(coalesce(p_payload,'{}'::jsonb)::text)>50000 then
    raise exception 'Sinal demasiado grande.';
  end if;

  delete from public.dama_signals where expires_at<=now();
  insert into public.dama_signals(
    room_id,from_player_id,to_player_id,signal_type,payload
  ) values(p_room,me,p_to_player,p_signal_type,p_payload)
  returning id into sid;

  return jsonb_build_object('ok',true,'id',sid);
end;
$$;

create or replace function public.jl_dama_signal_pull(
  p_token text,p_room uuid,p_after_id bigint default 0
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare me uuid:=public.jl_player_id(p_token);
begin
  if not public.jl_dama_is_member(p_room,me) then raise exception 'Sala inválida.'; end if;
  delete from public.dama_signals where expires_at<=now();

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',s.id,'from_player_id',s.from_player_id,
      'signal_type',s.signal_type,'payload',s.payload,'created_at',s.created_at
    ) order by s.id)
    from public.dama_signals s
    where s.room_id=p_room and s.to_player_id=me
      and s.id>coalesce(p_after_id,0) and s.expires_at>now()
  ),'[]'::jsonb);
end;
$$;

revoke all on function public.jl_dama_room_state(text,uuid) from public,anon,authenticated;
revoke all on function public.jl_dama_my_status(text) from public,anon,authenticated;
revoke all on function public.jl_dama_create_room(text,numeric,integer,text,text,boolean) from public,anon,authenticated;
revoke all on function public.jl_dama_public_rooms(text) from public,anon,authenticated;
revoke all on function public.jl_dama_join_room(text,text) from public,anon,authenticated;
revoke all on function public.jl_dama_update_settings(text,uuid,numeric,integer,text,text,boolean) from public,anon,authenticated;
revoke all on function public.jl_dama_accept_settings(text,uuid,boolean) from public,anon,authenticated;
revoke all on function public.jl_dama_commit_stake(text,uuid) from public,anon,authenticated;
revoke all on function public.jl_dama_process_timeout(text,uuid) from public,anon,authenticated;
revoke all on function public.jl_dama_move(text,uuid,text) from public,anon,authenticated;
revoke all on function public.jl_dama_offer_draw(text,uuid) from public,anon,authenticated;
revoke all on function public.jl_dama_respond_draw(text,uuid,boolean) from public,anon,authenticated;
revoke all on function public.jl_dama_forfeit(text,uuid) from public,anon,authenticated;
revoke all on function public.jl_dama_cancel(text,uuid) from public,anon,authenticated;
revoke all on function public.jl_dama_rematch(text,uuid,numeric,integer,text,text,boolean) from public,anon,authenticated;
revoke all on function public.jl_dama_signal_send(text,uuid,uuid,text,jsonb) from public,anon,authenticated;
revoke all on function public.jl_dama_signal_pull(text,uuid,bigint) from public,anon,authenticated;

grant execute on function public.jl_dama_room_state(text,uuid) to anon,authenticated;
grant execute on function public.jl_dama_my_status(text) to anon,authenticated;
grant execute on function public.jl_dama_create_room(text,numeric,integer,text,text,boolean) to anon,authenticated;
grant execute on function public.jl_dama_public_rooms(text) to anon,authenticated;
grant execute on function public.jl_dama_join_room(text,text) to anon,authenticated;
grant execute on function public.jl_dama_update_settings(text,uuid,numeric,integer,text,text,boolean) to anon,authenticated;
grant execute on function public.jl_dama_accept_settings(text,uuid,boolean) to anon,authenticated;
grant execute on function public.jl_dama_commit_stake(text,uuid) to anon,authenticated;
grant execute on function public.jl_dama_process_timeout(text,uuid) to anon,authenticated;
grant execute on function public.jl_dama_move(text,uuid,text) to anon,authenticated;
grant execute on function public.jl_dama_offer_draw(text,uuid) to anon,authenticated;
grant execute on function public.jl_dama_respond_draw(text,uuid,boolean) to anon,authenticated;
grant execute on function public.jl_dama_forfeit(text,uuid) to anon,authenticated;
grant execute on function public.jl_dama_cancel(text,uuid) to anon,authenticated;
grant execute on function public.jl_dama_rematch(text,uuid,numeric,integer,text,text,boolean) to anon,authenticated;
grant execute on function public.jl_dama_signal_send(text,uuid,uuid,text,jsonb) to anon,authenticated;
grant execute on function public.jl_dama_signal_pull(text,uuid,bigint) to anon,authenticated;

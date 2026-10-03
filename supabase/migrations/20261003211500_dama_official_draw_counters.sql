-- Dama Lendária: contadores de empate por jogador conforme regras brasileiras.
-- 20 lances sucessivos de damas DE CADA JOGADOR, sem captura ou deslocamento de pedra.
-- Finais regulamentares de 2/5 lances também são contados por jogador.

alter table public.dama_room_players
  add column if not exists quiet_dama_moves integer not null default 0,
  add column if not exists regulation_move_count integer not null default 0;

do $$
begin
  if not exists(
    select 1 from pg_constraint where conname='dama_room_players_quiet_dama_moves_check'
  ) then
    alter table public.dama_room_players
      add constraint dama_room_players_quiet_dama_moves_check check (quiet_dama_moves>=0);
  end if;
  if not exists(
    select 1 from pg_constraint where conname='dama_room_players_regulation_move_count_check'
  ) then
    alter table public.dama_room_players
      add constraint dama_room_players_regulation_move_count_check check (regulation_move_count>=0);
  end if;
end
$$;

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
  q1 integer:=0;
  q2 integer:=0;
  rg1 integer:=0;
  rg2 integer:=0;
begin
  select * into r from public.dama_rooms where id=p_room;
  if r.id is null or not public.jl_dama_is_member(p_room,me) then
    raise exception 'Sala de Dama não encontrada.';
  end if;

  if r.current_player_id=me and r.status in ('ready','playing') then
    legal:=public.jl_dama_legal_moves_data(p_room,me);
  end if;

  select coalesce(max(quiet_dama_moves) filter(where seat=1),0),
         coalesce(max(quiet_dama_moves) filter(where seat=2),0),
         coalesce(max(regulation_move_count) filter(where seat=1),0),
         coalesce(max(regulation_move_count) filter(where seat=2),0)
  into q1,q2,rg1,rg2
  from public.dama_room_players
  where room_id=p_room and status<>'left';

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
        'quiet_dama_moves',rp.quiet_dama_moves,
        'regulation_move_count',rp.regulation_move_count,
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
      'quiet_light',q1,
      'quiet_dark',q2,
      'quiet_light_remaining',greatest(0,20-q1),
      'quiet_dark_remaining',greatest(0,20-q2),
      'regulation_light',rg1,
      'regulation_dark',rg2,
      'regulation_limit',r.regulation_limit,
      'regulation_light_remaining',greatest(0,r.regulation_limit-rg1),
      'regulation_dark_remaining',greatest(0,r.regulation_limit-rg2),
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
  pkey text;
  occ integer;
  reg jsonb;
  reg_key text;
  reg_limit integer;
  new_seq integer;
  promoted boolean:=false;
  q_me integer:=0;
  q_other integer:=0;
  rg_me integer:=0;
  rg_other integer:=0;
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

  -- Contagem dos 20 lances: qualquer captura ou movimento de pedra zera ambos.
  if mover.is_king and cap_count=0 then
    update public.dama_room_players
    set quiet_dama_moves=quiet_dama_moves+1
    where room_id=p_room and player_id=me;
  else
    update public.dama_room_players
    set quiet_dama_moves=0
    where room_id=p_room and status<>'left';
  end if;

  reg:=public.jl_dama_regulation_state(p_room);
  reg_key:=reg->>'key';
  reg_limit:=coalesce((reg->>'limit')::integer,0);

  if reg_limit>0 then
    if r.regulation_key is distinct from reg_key then
      update public.dama_room_players
      set regulation_move_count=0
      where room_id=p_room and status<>'left';
    else
      update public.dama_room_players
      set regulation_move_count=regulation_move_count+1
      where room_id=p_room and player_id=me;
    end if;
  else
    update public.dama_room_players
    set regulation_move_count=0
    where room_id=p_room and status<>'left';
  end if;

  select coalesce(max(quiet_dama_moves) filter(where player_id=me),0),
         coalesce(max(quiet_dama_moves) filter(where player_id=nextp),0),
         coalesce(max(regulation_move_count) filter(where player_id=me),0),
         coalesce(max(regulation_move_count) filter(where player_id=nextp),0)
  into q_me,q_other,rg_me,rg_other
  from public.dama_room_players
  where room_id=p_room and status<>'left';

  update public.dama_rooms
  set status='playing',
      started_at=coalesce(started_at,now()),
      current_player_id=nextp,
      action_deadline=now()+make_interval(secs=>turn_seconds),
      move_seq=new_seq,
      board_version=board_version+1,
      quiet_king_moves=least(q_me,q_other),
      regulation_key=reg_key,
      regulation_moves=least(rg_me,rg_other),
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

  if q_me>=20 and q_other>=20 then
    perform public.jl_dama_finish_draw(p_room,'20_lances_de_damas_por_jogador');
    return public.jl_dama_room_state(p_token,p_room);
  end if;

  if reg_limit>0 and rg_me>=reg_limit and rg_other>=reg_limit then
    perform public.jl_dama_finish_draw(p_room,'empate_regulamentar');
    return public.jl_dama_room_state(p_token,p_room);
  end if;

  return public.jl_dama_room_state(p_token,p_room);
end;
$$;

-- Salas já abertas não devem herdar contadores antigos de mesa.
update public.dama_room_players rp
set quiet_dama_moves=0,regulation_move_count=0
where exists(
  select 1 from public.dama_rooms r
  where r.id=rp.room_id and r.status in ('waiting','negotiating','funding','ready')
);

revoke all on function public.jl_dama_room_state(text,uuid) from public,anon,authenticated;
revoke all on function public.jl_dama_move(text,uuid,text) from public,anon,authenticated;
grant execute on function public.jl_dama_room_state(text,uuid) to anon,authenticated;
grant execute on function public.jl_dama_move(text,uuid,text) to anon,authenticated;

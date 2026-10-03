-- Testes permanentes: Dama Lendária / regras brasileiras.
-- Executar como transação; nada deste teste permanece no banco.
begin;

do $$
declare
  ids uuid[];
  rid uuid;
  white_id uuid;
  red_id uuid;
  moves jsonb;
  reg jsonb;
begin
  select array_agg(id order by created_at,id)
  into ids
  from (
    select id,created_at
    from public.players
    where not blocked and deleted_at is null
    order by created_at,id
    limit 2
  ) p;

  if coalesce(array_length(ids,1),0)<2 then
    raise exception 'Teste Dama requer 2 jogadores.';
  end if;

  white_id:=ids[1];
  red_id:=ids[2];

  insert into public.dama_rooms(
    code,host_id,guest_id,bet_amount,turn_seconds,
    host_color,first_player_choice,is_public,status
  ) values(
    'DAMA-TEST-'||upper(substr(encode(extensions.gen_random_bytes(3),'hex'),1,6)),
    white_id,red_id,10,120,'white','host',false,'ready'
  ) returning id into rid;

  insert into public.dama_room_players(
    room_id,player_id,seat,color,settings_accepted,stake_paid
  ) values
    (rid,white_id,1,'white',true,true),
    (rid,red_id,2,'red',true,true);

  -- Posição inicial 8x8: brancas têm 7 movimentos simples.
  perform public.jl_dama_init_board(rid);
  moves:=public.jl_dama_legal_moves_data(rid,white_id);
  if jsonb_array_length(moves)<>7 then
    raise exception 'Dama: posição inicial deveria ter 7 movimentos; recebeu %',jsonb_array_length(moves);
  end if;

  -- Pedra captura para trás.
  delete from public.dama_pieces where room_id=rid;
  insert into public.dama_pieces(room_id,player_id,piece_no,row_no,col_no,is_king)
  values
    (rid,white_id,1,3,2,false),
    (rid,red_id,1,4,3,false);

  moves:=public.jl_dama_legal_moves_data(rid,white_id);
  if jsonb_array_length(moves)<>1
     or coalesce((moves->0->>'capture_count')::int,0)<>1
     or (moves->0->>'to_row')::int<>5
     or (moves->0->>'to_col')::int<>4 then
    raise exception 'Dama: captura para trás falhou: %',moves;
  end if;

  -- Lei da Maioria: rota de 2 capturas elimina da lista a opção de 1 captura.
  delete from public.dama_pieces where room_id=rid;
  insert into public.dama_pieces(room_id,player_id,piece_no,row_no,col_no,is_king)
  values
    (rid,white_id,1,5,0,false),
    (rid,white_id,2,5,4,false),
    (rid,red_id,1,4,1,false),
    (rid,red_id,2,4,5,false),
    (rid,red_id,3,2,5,false);

  moves:=public.jl_dama_legal_moves_data(rid,white_id);
  if jsonb_array_length(moves)<>1
     or (moves->0->>'piece_no')::int<>2
     or (moves->0->>'capture_count')::int<>2 then
    raise exception 'Dama: Lei da Maioria falhou: %',moves;
  end if;

  -- Dama voadora: uma captura pode terminar em qualquer casa livre além da peça capturada.
  delete from public.dama_pieces where room_id=rid;
  insert into public.dama_pieces(room_id,player_id,piece_no,row_no,col_no,is_king)
  values
    (rid,white_id,1,6,1,true),
    (rid,red_id,1,4,3,false);

  moves:=public.jl_dama_legal_moves_data(rid,white_id);
  if jsonb_array_length(moves)<>4 then
    raise exception 'Dama: captura longa deveria oferecer 4 destinos; recebeu %',jsonb_array_length(moves);
  end if;

  -- Passar pela linha de coroação no meio de uma captura não encerra a rota.
  delete from public.dama_pieces where room_id=rid;
  insert into public.dama_pieces(room_id,player_id,piece_no,row_no,col_no,is_king)
  values
    (rid,white_id,1,2,1,false),
    (rid,red_id,1,1,2,false),
    (rid,red_id,2,1,4,false);

  moves:=public.jl_dama_legal_moves_data(rid,white_id);
  if jsonb_array_length(moves)<>1
     or (moves->0->>'capture_count')::int<>2
     or (moves->0->>'to_row')::int<>2 then
    raise exception 'Dama: sequência pela coroação falhou: %',moves;
  end if;

  -- Final 1 dama contra 1 dama: limite regulamentar específico.
  delete from public.dama_pieces where room_id=rid;
  insert into public.dama_pieces(room_id,player_id,piece_no,row_no,col_no,is_king)
  values
    (rid,white_id,1,6,1,true),
    (rid,red_id,1,1,6,true);

  reg:=public.jl_dama_regulation_state(rid);
  if coalesce((reg->>'limit')::int,0)<>2 then
    raise exception 'Dama: final 1 dama x 1 dama deveria ter limite 2: %',reg;
  end if;
end
$$;

rollback;

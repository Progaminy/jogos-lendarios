-- Dama Lendária — regressão permanente: captura obrigatória + Lei da Maioria.
-- Seguro para produção: tudo acontece dentro de uma transação revertida no final.

begin;

do $$
declare
  a uuid;
  b uuid;
  rid uuid:=extensions.gen_random_uuid();
  a1 uuid;
  a2 uuid;
  moves jsonb;
  item jsonb;
begin
  select id into a
  from public.players
  where not blocked and deleted_at is null
  order by created_at,id
  limit 1;

  select id into b
  from public.players
  where not blocked and deleted_at is null and id<>a
  order by created_at,id
  limit 1;

  if a is null or b is null then
    raise exception 'TEST Dama: são necessários dois jogadores';
  end if;

  insert into public.dama_rooms(
    id,code,host_id,guest_id,bet_amount,turn_seconds,host_color,
    first_player_choice,status,current_player_id
  ) values(
    rid,'TST-'||substr(replace(rid::text,'-',''),1,8),
    a,b,10,120,'white','host','ready',a
  );

  insert into public.dama_room_players(
    room_id,player_id,seat,color,settings_accepted,stake_paid
  ) values
    (rid,a,1,'white',true,true),
    (rid,b,2,'red',true,true);

  -- A1 pode capturar duas peças.
  insert into public.dama_pieces(
    room_id,player_id,piece_no,row_no,col_no,is_king
  ) values(rid,a,1,5,0,false)
  returning id into a1;

  insert into public.dama_pieces(
    room_id,player_id,piece_no,row_no,col_no,is_king
  ) values
    (rid,b,1,4,1,false),
    (rid,b,2,2,3,false);

  -- A2 pode capturar somente uma peça.
  insert into public.dama_pieces(
    room_id,player_id,piece_no,row_no,col_no,is_king
  ) values(rid,a,2,5,4,false)
  returning id into a2;

  insert into public.dama_pieces(
    room_id,player_id,piece_no,row_no,col_no,is_king
  ) values(rid,b,3,4,5,false);

  moves:=public.jl_dama_legal_moves_data(rid,a);

  if jsonb_array_length(moves)<>1 then
    raise exception
      'Lei da Maioria falhou: esperado 1 caminho máximo, recebido %',
      jsonb_array_length(moves);
  end if;

  item:=moves->0;

  if (item->>'piece_id')::uuid<>a1 then
    raise exception
      'Lei da Maioria falhou: caminho de menor captura foi oferecido';
  end if;

  if (item->>'capture_count')::integer<>2 then
    raise exception
      'Captura múltipla falhou: esperado 2, recebido %',
      item->>'capture_count';
  end if;

  if not (item->>'is_capture')::boolean then
    raise exception 'Captura obrigatória falhou';
  end if;
end
$$;

rollback;

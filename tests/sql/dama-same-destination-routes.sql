-- Dama brasileira — duas rotas máximas distintas podem terminar na mesma casa.
-- O servidor deve devolver ambas; o frontend mostra o seletor de rota.

begin;

do $$
declare
  a uuid:=extensions.gen_random_uuid();
  b uuid:=extensions.gen_random_uuid();
  rid uuid:=extensions.gen_random_uuid();
  moves jsonb;
  same_dest integer;
  maxcap integer;
begin
  insert into public.players(id,name,phone,pin_hash,balance)
  values
    (a,'Rota Dama A','ROTA-A-'||substr(a::text,1,8),extensions.crypt('1234',extensions.gen_salt('bf')),0),
    (b,'Rota Dama B','ROTA-B-'||substr(b::text,1,8),extensions.crypt('1234',extensions.gen_salt('bf')),0);

  insert into public.dama_rooms(
    id,code,host_id,guest_id,bet_amount,turn_seconds,host_color,
    first_player_choice,status,current_player_id
  ) values(rid,'TST-ROTA',a,b,10,120,'white','host','ready',a);

  insert into public.dama_room_players(room_id,player_id,seat,color,settings_accepted)
  values(rid,a,1,'white',true),(rid,b,2,'red',true);

  insert into public.dama_pieces(room_id,player_id,piece_no,row_no,col_no,is_king)
  values
    (rid,a,1,0,1,true),
    (rid,b,1,0,3,false),
    (rid,b,2,1,2,false),
    (rid,b,3,4,5,false);

  moves:=public.jl_dama_legal_moves_data(rid,a);

  select max((value->>'capture_count')::int)
  into maxcap
  from jsonb_array_elements(moves);

  select count(*)
  into same_dest
  from jsonb_array_elements(moves)
  where (value->>'capture_count')::int=maxcap
    and (value->>'to_row')::int=5
    and (value->>'to_col')::int=6;

  if maxcap<>2 then
    raise exception 'ROTA: captura máxima esperada 2, recebida %',maxcap;
  end if;
  if same_dest<2 then
    raise exception 'ROTA: esperado >=2 rotas legais para o mesmo destino, recebido %',same_dest;
  end if;
end
$$;

rollback;

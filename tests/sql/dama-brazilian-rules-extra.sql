-- Dama brasileira — regressões de regras e produto.
-- ROLLBACK garante que nenhuma conta/partida real é alterada.

begin;

do $$
declare
  a uuid:=extensions.gen_random_uuid();
  b uuid:=extensions.gen_random_uuid();
  ta text:='dama-rule-a-'||replace(extensions.gen_random_uuid()::text,'-','');
  tb text:='dama-rule-b-'||replace(extensions.gen_random_uuid()::text,'-','');
  rid uuid;
  piece uuid;
  moves jsonb;
  route text;
  code text;
  s jsonb;
  cp uuid;
  tok text;
  i int;
  promoted boolean;
  rejected_blocked boolean:=false;
begin
  insert into public.players(id,name,phone,pin_hash,balance)
  values
    (a,'Regra Dama A','REG-A-'||substr(a::text,1,8),extensions.crypt('1234',extensions.gen_salt('bf')),100),
    (b,'Regra Dama B','REG-B-'||substr(b::text,1,8),extensions.crypt('1234',extensions.gen_salt('bf')),100);

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values
    (a,public.jl_token_hash(ta),now()+interval '1 hour'),
    (b,public.jl_token_hash(tb),now()+interval '1 hour');

  -- Pedra captura para trás.
  rid:=extensions.gen_random_uuid();
  insert into public.dama_rooms(id,code,host_id,guest_id,bet_amount,turn_seconds,host_color,first_player_choice,status,current_player_id)
  values(rid,'TST-BACK',a,b,10,120,'white','host','ready',a);
  insert into public.dama_room_players(room_id,player_id,seat,color,settings_accepted)
  values(rid,a,1,'white',true),(rid,b,2,'red',true);
  insert into public.dama_pieces(room_id,player_id,piece_no,row_no,col_no,is_king)
  values(rid,a,1,3,2,false),(rid,b,1,4,3,false),(rid,b,2,0,1,false);

  moves:=public.jl_dama_legal_moves_data(rid,a);
  if not exists(
    select 1 from jsonb_array_elements(moves)
    where (value->>'is_capture')::boolean
      and (value->>'from_row')::int=3 and (value->>'from_col')::int=2
      and (value->>'to_row')::int=5 and (value->>'to_col')::int=4
  ) then
    raise exception 'REGRA: pedra não capturou para trás';
  end if;

  delete from public.dama_rooms where id=rid;

  -- Passar pela última linha durante captura não promove se o lance terminar fora dela.
  rid:=extensions.gen_random_uuid();
  insert into public.dama_rooms(id,code,host_id,guest_id,bet_amount,turn_seconds,host_color,first_player_choice,status,current_player_id)
  values(rid,'TST-PROM',a,b,10,120,'white','host','ready',a);
  insert into public.dama_room_players(room_id,player_id,seat,color,settings_accepted)
  values(rid,a,1,'white',true),(rid,b,2,'red',true);

  insert into public.dama_pieces(room_id,player_id,piece_no,row_no,col_no,is_king)
  values(rid,a,1,2,1,false) returning id into piece;
  insert into public.dama_pieces(room_id,player_id,piece_no,row_no,col_no,is_king)
  values
    (rid,b,1,1,2,false),
    (rid,b,2,1,4,false),
    (rid,b,3,7,0,false);

  s:=public.jl_dama_room_state(ta,rid);
  select value->>'route_id' into route
  from jsonb_array_elements(s->'legal_moves')
  where (value->>'capture_count')::int=2
    and (value->>'to_row')::int=2 and (value->>'to_col')::int=5
  limit 1;

  if route is null then raise exception 'REGRA: sequência de duas capturas não encontrada'; end if;
  perform public.jl_dama_move(ta,rid,route);
  select is_king into promoted from public.dama_pieces where id=piece;
  if promoted then raise exception 'REGRA: promoção aconteceu antes do fim da sequência'; end if;

  delete from public.dama_rooms where id=rid;

  -- Terminar na última linha promove.
  rid:=extensions.gen_random_uuid();
  insert into public.dama_rooms(id,code,host_id,guest_id,bet_amount,turn_seconds,host_color,first_player_choice,status,current_player_id)
  values(rid,'TST-CROWN',a,b,10,120,'white','host','ready',a);
  insert into public.dama_room_players(room_id,player_id,seat,color,settings_accepted)
  values(rid,a,1,'white',true),(rid,b,2,'red',true);
  insert into public.dama_pieces(room_id,player_id,piece_no,row_no,col_no,is_king)
  values(rid,a,1,2,1,false) returning id into piece;
  insert into public.dama_pieces(room_id,player_id,piece_no,row_no,col_no,is_king)
  values(rid,b,1,1,2,false),(rid,b,2,7,0,false);

  s:=public.jl_dama_room_state(ta,rid);
  select value->>'route_id' into route
  from jsonb_array_elements(s->'legal_moves')
  where (value->>'to_row')::int=0 and (value->>'to_col')::int=3
  limit 1;

  if route is null then raise exception 'REGRA: captura de promoção não encontrada'; end if;
  perform public.jl_dama_move(ta,rid,route);
  select is_king into promoted from public.dama_pieces where id=piece;
  if not promoted then raise exception 'REGRA: peça não foi promovida ao terminar na última linha'; end if;

  delete from public.dama_rooms where id=rid;

  -- Empate recusado: nova proposta só depois de 2 jogadas de cada jogador.
  s:=public.jl_dama_create_room(ta,10,120,'white','host',false);
  rid:=(s->'room'->>'id')::uuid;
  code:=s->'room'->>'code';
  perform public.jl_dama_join_room(tb,code);
  perform public.jl_dama_accept_settings(tb,rid,true);
  perform public.jl_dama_commit_stake(ta,rid);
  perform public.jl_dama_commit_stake(tb,rid);

  s:=public.jl_dama_room_state(ta,rid);
  route:=s->'legal_moves'->0->>'route_id';
  perform public.jl_dama_move(ta,rid,route);

  perform public.jl_dama_offer_draw(ta,rid);
  perform public.jl_dama_respond_draw(tb,rid,false);

  begin
    perform public.jl_dama_offer_draw(ta,rid);
  exception when others then
    if sqlerrm ilike '%2 jogadas de cada jogador%' then
      rejected_blocked:=true;
    else
      raise;
    end if;
  end;

  if not rejected_blocked then
    raise exception 'EMPATE: nova proposta foi permitida cedo demais';
  end if;

  for i in 1..4 loop
    select current_player_id into cp from public.dama_rooms where id=rid;
    tok:=case when cp=a then ta else tb end;
    s:=public.jl_dama_room_state(tok,rid);
    route:=s->'legal_moves'->0->>'route_id';
    if route is null then raise exception 'EMPATE: sem jogada no passo %',i; end if;
    perform public.jl_dama_move(tok,rid,route);
  end loop;

  perform public.jl_dama_offer_draw(ta,rid);
  if (select draw_offer_by from public.dama_rooms where id=rid)<>a then
    raise exception 'EMPATE: nova proposta não foi permitida após 2 jogadas de cada';
  end if;
end
$$;

rollback;

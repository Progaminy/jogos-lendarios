-- Dama Lendária — E2E transacional.
-- Usa jogadores temporários e ROLLBACK: não altera contas, saldos ou partidas reais.

begin;

do $$
declare
  pa uuid:=extensions.gen_random_uuid();
  pb uuid:=extensions.gen_random_uuid();
  ta text:='dama-e2e-a-'||replace(extensions.gen_random_uuid()::text,'-','');
  tb text:='dama-e2e-b-'||replace(extensions.gen_random_uuid()::text,'-','');
  s jsonb;
  rid uuid;
  code text;
  route text;
  bal_a numeric;
  bal_b numeric;
  pre_a numeric;
  pre_b numeric;
  r public.dama_rooms%rowtype;
begin
  insert into public.players(id,name,phone,pin_hash,balance)
  values
    (pa,'Teste Dama A','E2E-A-'||substr(pa::text,1,8),extensions.crypt('1234',extensions.gen_salt('bf')),100),
    (pb,'Teste Dama B','E2E-B-'||substr(pb::text,1,8),extensions.crypt('1234',extensions.gen_salt('bf')),100);

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values
    (pa,public.jl_token_hash(ta),now()+interval '1 hour'),
    (pb,public.jl_token_hash(tb),now()+interval '1 hour');

  -- 1. Pré-início: depois das duas apostas fica READY, sem relógio.
  s:=public.jl_dama_create_room(ta,20,120,'white','host',false);
  rid:=(s->'room'->>'id')::uuid;
  code:=s->'room'->>'code';

  if s->'room'->>'status'<>'waiting' then raise exception 'E2E1 create: status inesperado'; end if;

  s:=public.jl_dama_join_room(tb,code);
  if s->'room'->>'status'<>'negotiating' then raise exception 'E2E1 join: status inesperado'; end if;

  perform public.jl_dama_accept_settings(tb,rid,true);
  if (select status from public.dama_rooms where id=rid)<>'funding' then
    raise exception 'E2E1 accept: funding não ativou';
  end if;

  perform public.jl_dama_commit_stake(ta,rid);
  perform public.jl_dama_commit_stake(tb,rid);

  select * into r from public.dama_rooms where id=rid;
  if r.status<>'ready' or r.started_at is not null or r.action_deadline is not null then
    raise exception 'E2E1 ready: cronómetro iniciou antes da primeira jogada';
  end if;
  if r.pot<>40 then raise exception 'E2E1 pot: esperado 40, recebido %',r.pot; end if;
  if (select count(*) from public.dama_pieces where room_id=rid and alive)<>24 then
    raise exception 'E2E1 board: esperado 24 peças';
  end if;

  -- Cancelar antes da primeira jogada: zero penalização.
  perform public.jl_dama_cancel(tb,rid);
  select * into r from public.dama_rooms where id=rid;
  select balance into bal_a from public.players where id=pa;
  select balance into bal_b from public.players where id=pb;
  if r.status<>'cancelled' or r.pot<>0 or bal_a<>100 or bal_b<>100 then
    raise exception 'E2E1 cancel/refund: status %, pot %, A %, B %',r.status,r.pot,bal_a,bal_b;
  end if;

  -- 2. Primeira jogada inicia relógio; desistência paga o vencedor.
  s:=public.jl_dama_create_room(ta,20,120,'white','host',false);
  rid:=(s->'room'->>'id')::uuid;
  code:=s->'room'->>'code';
  perform public.jl_dama_join_room(tb,code);
  perform public.jl_dama_accept_settings(tb,rid,true);
  perform public.jl_dama_commit_stake(ta,rid);
  perform public.jl_dama_commit_stake(tb,rid);

  s:=public.jl_dama_room_state(ta,rid);
  route:=s->'legal_moves'->0->>'route_id';
  if coalesce(route,'')='' then raise exception 'E2E2: primeira jogada legal não encontrada'; end if;
  perform public.jl_dama_move(ta,rid,route);

  select * into r from public.dama_rooms where id=rid;
  if r.status<>'playing' or r.started_at is null or r.action_deadline is null or r.move_seq<>1 then
    raise exception 'E2E2: primeira jogada não iniciou partida/relógio';
  end if;
  if extract(epoch from (r.action_deadline-now())) not between 115 and 121 then
    raise exception 'E2E2: relógio não respeitou 120 s';
  end if;

  perform public.jl_dama_forfeit(tb,rid);
  select * into r from public.dama_rooms where id=rid;
  select balance into bal_a from public.players where id=pa;
  select balance into bal_b from public.players where id=pb;
  if r.status<>'finished' or r.winner_player_id<>pa or r.result_reason<>'desistencia' then
    raise exception 'E2E2: desistência não terminou corretamente';
  end if;
  if r.commission_total<>1 or bal_a<>119 or bal_b<>80 then
    raise exception 'E2E2 payout: comissão %, A %, B %',r.commission_total,bal_a,bal_b;
  end if;

  -- Revanche: todas as definições podem mudar.
  s:=public.jl_dama_rematch(ta,rid,30,180,'red','guest',false);
  if s->'room'->>'status'<>'negotiating'
     or (s->'room'->>'bet_amount')::numeric<>30
     or (s->'room'->>'turn_seconds')::int<>180
     or s->'room'->>'host_color'<>'red'
     or s->'room'->>'first_player_choice'<>'guest' then
    raise exception 'E2E2 revanche: definições não foram aplicadas';
  end if;
  perform public.jl_dama_cancel(ta,(s->'room'->>'id')::uuid);

  -- 3. Timeout: o jogador cujo tempo chega a zero perde.
  s:=public.jl_dama_create_room(ta,20,120,'white','host',false);
  rid:=(s->'room'->>'id')::uuid;
  code:=s->'room'->>'code';
  perform public.jl_dama_join_room(tb,code);
  perform public.jl_dama_accept_settings(tb,rid,true);
  perform public.jl_dama_commit_stake(ta,rid);
  perform public.jl_dama_commit_stake(tb,rid);
  s:=public.jl_dama_room_state(ta,rid);
  route:=s->'legal_moves'->0->>'route_id';
  perform public.jl_dama_move(ta,rid,route);

  update public.dama_rooms set action_deadline=now()-interval '1 second' where id=rid;
  perform public.jl_dama_process_timeout(ta,rid);
  select * into r from public.dama_rooms where id=rid;
  if r.status<>'finished' or r.winner_player_id<>pa or r.result_reason<>'timeout' then
    raise exception 'E2E3 timeout: vencedor/estado incorreto';
  end if;

  -- 4. Empate acordado: devolução integral, comissão zero.
  select balance into pre_a from public.players where id=pa;
  select balance into pre_b from public.players where id=pb;

  s:=public.jl_dama_create_room(ta,20,120,'white','host',false);
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
  perform public.jl_dama_respond_draw(tb,rid,true);

  select * into r from public.dama_rooms where id=rid;
  select balance into bal_a from public.players where id=pa;
  select balance into bal_b from public.players where id=pb;
  if r.status<>'finished' or r.winner_player_id is not null
     or r.result_reason<>'acordo' or r.commission_total<>0 then
    raise exception 'E2E4 empate: estado/comissão incorretos';
  end if;
  if bal_a<>pre_a or bal_b<>pre_b then
    raise exception 'E2E4 empate: antes A/B %/%, depois %/%',pre_a,pre_b,bal_a,bal_b;
  end if;
end
$$;

rollback;

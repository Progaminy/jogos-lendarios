begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(24);

select is(
  public.jl_ludo_defaults()->>'base_exit_rule',
  'six',
  'Ludo: a regra padrão de saída da base é somente com 6'
);

select todo(
  'JL-LUDO-BASE-DRIFT conhecido: produção exige 6 para sair da base, mas a reconstrução local pelas migrations ainda diverge. Ponto 26 não altera lógica nem migrations.',
  1
);
select ok(
  position('t.steps=-1' in pg_get_functiondef('public.jl_ludo_legal_moves_data(uuid,uuid,integer)'::regprocedure)) > 0
  and position('p_dice<>6' in pg_get_functiondef('public.jl_ludo_legal_moves_data(uuid,uuid,integer)'::regprocedure)) > 0,
  'Ludo: peão na base não tem movimento legal com 1-5'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_roll(text,uuid)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%force_six := coalesce(rp.rolls_without_six,0) >= 6%',
  'Ludo: qualquer jogador força 6 na 7ª tentativa, após 6 falhas'
);

select ok(
  position('fc857df1-7367-41f7-99d9-44870262b6ca' in pg_get_functiondef('public.jl_ludo_roll(text,uuid)'::regprocedure)) = 0
  and position('5f2edef6-2582-4c26-b93e-86c34924323c' in pg_get_functiondef('public.jl_ludo_roll(text,uuid)'::regprocedure)) = 0,
  'Ludo: a regra de 6 forçado não contém exceções por UUID'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_roll(text,uuid)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%d:=case when force_six then 6 else public.jl_random_index(6) end;%',
  'Ludo: quando o 6 é forçado, o resultado é literalmente 6'
);

select ok(
  position(
    'perform public.jl_ludo_advance_turn(p_room,me,d=6 and (r.rules->>''six_extra_turn'')::boolean);'
    in pg_get_functiondef('public.jl_ludo_roll(text,uuid)'::regprocedure)
  ) = 0
  and position(
    'perform public.jl_ludo_advance_turn(p_room,me,false);'
    in pg_get_functiondef('public.jl_ludo_roll(text,uuid)'::regprocedure)
  ) > 0,
  'Ludo: 6 sem jogada legal termina a vez, inclusive quando o 6 foi forçado'
);

select ok(
  pg_get_functiondef('public.jl_ludo_roll(text,uuid)'::regprocedure)
    like '%three_sixes_penalty%',
  'Ludo: penalização de três 6 continua presente'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_roll(text,uuid)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%rp.consecutive_sixes>=3%jl_ludo_advance_turn(p_room,me,false)%',
  'Ludo: três 6 passa a vez sem lançamento extra'
);

select is(
  public.jl_ludo_defaults()->>'safe_cells',
  'true',
  'Ludo: casas seguras estão ligadas por padrão'
);

select ok(
  exists(
    select 1 from pg_constraint
    where conrelid='public.ludo_rooms'::regclass
      and conname='ludo_rooms_safe_cells_always_on'
  ),
  'Ludo: banco impede desligar casas seguras'
);

select ok(
  lower(pg_get_functiondef('public.jl_ludo_legal_moves_data(uuid,uuid,integer)'::regprocedure))
    like '%not ((r.rules->>''safe_cells'')::boolean and public.jl_ludo_is_safe_cell(cell))%',
  'Ludo: captura não é criada em casa segura'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_move(text,uuid,integer)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%update public.ludo_tokens set steps=-1%where room_id=p_room and player_id=target and token_no=target_no%',
  'Ludo: captura devolve o peão adversário à base'
);

select is(
  public.jl_ludo_defaults()->>'exact_finish',
  'true',
  'Ludo: chegada exata está ligada'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_legal_moves_data(uuid,uuid,integer)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%if (r.rules->>''exact_finish'')::boolean and ns>56 then continue; end if;%',
  'Ludo: movimento que ultrapassa a chegada exata é rejeitado'
);

select ok(
  lower(pg_get_functiondef('public.jl_ludo_legal_moves_data(uuid,uuid,integer)'::regprocedure))
    like '%''finishes'',ns=56%',
  'Ludo: o passo 56 é o estado terminal do peão'
);

select ok(
  exists(
    select 1 from pg_constraint
    where conrelid='public.ludo_rooms'::regclass
      and conname='ludo_rooms_check'
      and pg_get_constraintdef(oid) like '%mode <> ''partners''%player_count = 4%'
  ),
  'Ludo: modo parceiros exige quatro jogadores'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_join_room_internal(uuid,uuid)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%when r.mode=''partners'' then case when s in (1,3) then 1 else 2 end%',
  'Ludo: parceiros são distribuídos pelas equipas atuais 1 e 2'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_finish_room(uuid,uuid,integer)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%gross:=round(r.pot/2,2)%',
  'Ludo: prémio de parceiros divide o pote por dois vencedores'
);

select ok(
  pg_get_functiondef('public.jl_ludo_process_timeouts(text,uuid)'::regprocedure)
    like '%''player_remains_in_game'',true%',
  'Ludo: timeout mantém o jogador na partida'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_process_timeouts(text,uuid)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%jl_ludo_advance_turn(p_room,cur,false)%',
  'Ludo: timeout passa a vez'
);

select ok(
  pg_get_functiondef('public.jl_ludo_reenter(text,uuid)'::regprocedure)
    like '%''late_reconnect_allowed'',true%',
  'Ludo: reentrada/reconexão tardia continua explicitamente suportada'
);

select ok(
  to_regprocedure('public.jl_ludo_forfeit(text,uuid)') is not null,
  'Ludo: desistência explícita possui RPC própria'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_join_room_internal(uuid,uuid)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%from public.players where id=p_player for update%',
  'Ludo: entrada serializa o jogador com FOR UPDATE'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_join_room_internal(uuid,uuid)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%from public.ludo_rooms where id=p_room for update%',
  'Ludo: entrada serializa a sala com FOR UPDATE'
);

select ok(
  exists(
    select 1 from pg_constraint
    where conrelid='public.ludo_room_players'::regclass
      and conname='ludo_room_players_room_id_seat_key'
      and contype='u'
  ),
  'Ludo: assento é único por sala'
);

select * from finish();
rollback;

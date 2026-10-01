begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(8);

select has_column('public','ludo_rooms','pawn_count','Ludo: sala guarda quantidade de peões');

select col_default_is(
  'public','ludo_rooms','pawn_count','4',
  'Ludo: salas antigas e clientes antigos usam 4 peões por padrão'
);

select ok(
  exists(
    select 1
    from pg_constraint
    where conrelid='public.ludo_rooms'::regclass
      and conname='ludo_rooms_pawn_count_check'
      and pg_get_constraintdef(oid) like '%pawn_count >= 1%'
      and pg_get_constraintdef(oid) like '%pawn_count <= 4%'
  ),
  'Ludo: banco aceita somente 1 a 4 peões'
);

select ok(
  lower(pg_get_functiondef('public.jl_ludo_create_room(text,integer,numeric,text,boolean,jsonb)'::regprocedure))
    like '%pawn_count%'
  and lower(pg_get_functiondef('public.jl_ludo_create_room(text,integer,numeric,text,boolean,jsonb)'::regprocedure))
    like '%quantidade de peões deve ser 1, 2, 3 ou 4%',
  'Ludo: criação valida e persiste quantidade de peões'
);

select ok(
  lower(pg_get_functiondef('public.jl_ludo_start_game(uuid)'::regprocedure))
    like '%generate_series(1,r.pawn_count)%',
  'Ludo: início cria somente a quantidade configurada de peões'
);

select ok(
  lower(pg_get_functiondef('public.jl_ludo_check_finish(uuid)'::regprocedure))
    like '%r.pawn_count=%'
  and lower(pg_get_functiondef('public.jl_ludo_check_finish(uuid)'::regprocedure))
    like '%t.steps=56%',
  'Ludo: vitória exige que todos os peões ativos cheguem'
);

select ok(
  lower(pg_get_functiondef('public.jl_ludo_rematch(text,uuid,numeric)'::regprocedure))
    like '%jsonb_build_object(''pawn_count'',r.pawn_count)%',
  'Ludo: revanche preserva quantidade de peões'
);

select ok(
  not has_function_privilege('anon','public.jl_ludo_start_game(uuid)','EXECUTE')
  and not has_function_privilege('authenticated','public.jl_ludo_start_game(uuid)','EXECUTE')
  and not has_function_privilege('anon','public.jl_ludo_check_finish(uuid)','EXECUTE')
  and not has_function_privilege('authenticated','public.jl_ludo_check_finish(uuid)','EXECUTE'),
  'Ludo: funções internas de peões continuam bloqueadas ao browser'
);

select * from finish();
rollback;

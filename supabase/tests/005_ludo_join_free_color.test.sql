begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(4);

select ok(
  to_regprocedure('public.jl_ludo_join_room_internal(uuid,uuid)') is not null,
  'Ludo: helper interno de entrada existe'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_join_room_internal(uuid,uuid)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%preferred_col%'
  and lower(regexp_replace(pg_get_functiondef('public.jl_ludo_join_room_internal(uuid,uuid)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%where not exists(%rp.color=c%',
  'Ludo: entrada de 3/4 jogadores escolhe uma cor realmente livre'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_join_room_internal(uuid,uuid)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%select * into r%from public.ludo_rooms%for update%',
  'Ludo: entrada continua serializada pelo bloqueio da sala'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_join_room_internal(uuid,uuid)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%if r.player_count=2 then%'
  and lower(regexp_replace(pg_get_functiondef('public.jl_ludo_join_room_internal(uuid,uuid)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%when ''red'' then ''yellow''%'
  and lower(regexp_replace(pg_get_functiondef('public.jl_ludo_join_room_internal(uuid,uuid)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%when ''green'' then ''blue''%',
  'Ludo: regra de cores opostas para 2 jogadores foi preservada'
);

select * from finish();
rollback;

begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(5);

select ok(
  to_regprocedure('public.jl_ludo_choose_color(text,uuid,text)') is not null,
  'Ludo: RPC de escolha de cor existe'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_choose_color(text,uuid,text)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%when ''red'' then ''yellow''%'
  and lower(regexp_replace(pg_get_functiondef('public.jl_ludo_choose_color(text,uuid,text)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%when ''yellow'' then ''red''%'
  and lower(regexp_replace(pg_get_functiondef('public.jl_ludo_choose_color(text,uuid,text)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%when ''green'' then ''blue''%'
  and lower(regexp_replace(pg_get_functiondef('public.jl_ludo_choose_color(text,uuid,text)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%when ''blue'' then ''green''%',
  'Ludo: escolha de cor conhece os dois pares opostos'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_choose_color(text,uuid,text)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%if r.player_count=2 then%'
  and lower(regexp_replace(pg_get_functiondef('public.jl_ludo_choose_color(text,uuid,text)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%set color=opposite_color%',
  'Ludo: em sala de 2 a troca de cor reposiciona o adversário na casa oposta'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_join_room_internal(uuid,uuid)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%if r.player_count=2 then%'
  and lower(regexp_replace(pg_get_functiondef('public.jl_ludo_join_room_internal(uuid,uuid)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%when ''red'' then ''yellow''%'
  and lower(regexp_replace(pg_get_functiondef('public.jl_ludo_join_room_internal(uuid,uuid)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%when ''green'' then ''blue''%',
  'Ludo: segundo jogador entra na cor oposta à cor já escolhida'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_choose_color(text,uuid,text)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%for update%',
  'Ludo: escolha de cor é serializada para evitar combinações concorrentes inválidas'
);

select * from finish();
rollback;

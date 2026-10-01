begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(5);

select is(
  public.jl_ludo_defaults()->>'blockades',
  'false',
  'Ludo: várias peças podem ocupar a mesma casa'
);

select ok(
  exists(
    select 1
    from pg_constraint
    where conrelid='public.ludo_rooms'::regclass
      and conname='ludo_rooms_blockades_always_off'
  ),
  'Ludo: o banco impede bloqueios por casa ocupada'
);

select ok(
  lower(regexp_replace(
    pg_get_functiondef('public.jl_ludo_legal_moves_data(uuid,uuid,integer)'::regprocedure),
    E'\\s+', ' ', 'g'
  )) like '%jsonb_agg(jsonb_build_object(''player_id'',ot.player_id,''token_no'',ot.token_no))%',
  'Ludo: o movimento recolhe todos os peões adversários da casa'
);

select ok(
  lower(regexp_replace(
    pg_get_functiondef('public.jl_ludo_move(text,uuid,integer)'::regprocedure),
    E'\\s+', ' ', 'g'
  )) like '%for c in select value from jsonb_array_elements(m->''captures'') loop%'
  and lower(regexp_replace(
    pg_get_functiondef('public.jl_ludo_move(text,uuid,integer)'::regprocedure),
    E'\\s+', ' ', 'g'
  )) like '%update public.ludo_tokens set steps=-1%player_id=target%token_no=target_no%',
  'Ludo: ao cair na casa, todos os peões adversários capturados regressam à base'
);

select ok(
  lower(regexp_replace(
    pg_get_functiondef('public.jl_ludo_legal_moves_data(uuid,uuid,integer)'::regprocedure),
    E'\\s+', ' ', 'g'
  )) not like '%having count(*)>=2%',
  'Ludo: quantidade de peões numa casa não transforma a casa em bloqueio'
);

select * from finish();
rollback;

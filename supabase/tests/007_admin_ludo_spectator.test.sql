begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(4);

select ok(
  to_regprocedure('public.jl_admin_ludo_watch_room(text,uuid)') is not null,
  'Admin: snapshot de espectador Ludo existe'
);

select ok(
  lower(pg_get_functiondef('public.jl_admin_ludo_watch_room(text,uuid)'::regprocedure))
    like '%jl_admin_ok%'
  and lower(pg_get_functiondef('public.jl_admin_ludo_watch_room(text,uuid)'::regprocedure))
    like '%ludo_tokens%'
  and lower(pg_get_functiondef('public.jl_admin_ludo_watch_room(text,uuid)'::regprocedure))
    like '%ludo_room_players%',
  'Admin: snapshot valida sessão e lê estado necessário da partida'
);

select ok(
  has_function_privilege('anon','public.jl_admin_ludo_watch_room(text,uuid)','EXECUTE')
  and not has_function_privilege('authenticated','public.jl_admin_ludo_watch_room(text,uuid)','EXECUTE'),
  'Admin: RPC é acessível pelo cliente admin anon e não pela role authenticated'
);

select ok(
  lower(pg_get_functiondef('public.jl_admin_ludo_watch_room(text,uuid)'::regprocedure))
    not like '%update public.%'
  and lower(pg_get_functiondef('public.jl_admin_ludo_watch_room(text,uuid)'::regprocedure))
    not like '%delete from public.%'
  and lower(pg_get_functiondef('public.jl_admin_ludo_watch_room(text,uuid)'::regprocedure))
    not like '%insert into public.%',
  'Admin: espectador é somente leitura'
);

select * from finish();
rollback;

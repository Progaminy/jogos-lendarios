begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(6);

select ok(
  to_regprocedure('public.jl_ludo_realtime_broadcast_sync()') is not null,
  'Ludo: função interna de Broadcast existe'
);

select ok(
  lower(pg_get_functiondef('public.jl_ludo_realtime_broadcast_sync()'::regprocedure))
    like '%realtime.send%'
  and lower(pg_get_functiondef('public.jl_ludo_realtime_broadcast_sync()'::regprocedure))
    like '%ludo:room:%',
  'Ludo: Broadcast usa tópico por sala'
);

select ok(
  exists(
    select 1
    from pg_trigger t
    join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relname='ludo_events'
      and t.tgname='jl_ludo_events_realtime_sync'
      and not t.tgisinternal
  ),
  'Ludo: eventos disparam sincronização Realtime'
);

select ok(
  exists(
    select 1
    from pg_trigger t
    join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relname='ludo_chat'
      and t.tgname='jl_ludo_chat_realtime_sync'
      and not t.tgisinternal
  ),
  'Ludo: chat dispara sincronização Realtime'
);

select ok(
  not has_function_privilege(
    'anon',
    'public.jl_ludo_realtime_broadcast_sync()',
    'EXECUTE'
  )
  and not has_function_privilege(
    'authenticated',
    'public.jl_ludo_realtime_broadcast_sync()',
    'EXECUTE'
  ),
  'Ludo: função interna de Broadcast não é executável pelo cliente'
);

select ok(
  lower(pg_get_functiondef('public.jl_ludo_realtime_broadcast_sync()'::regprocedure))
    like '%dice_rolled%'
  and lower(pg_get_functiondef('public.jl_ludo_realtime_broadcast_sync()'::regprocedure))
    like '%player_id%'
  and lower(pg_get_functiondef('public.jl_ludo_realtime_broadcast_sync()'::regprocedure))
    like '%dice_values%',
  'Ludo: Broadcast inclui jogador e resultado público do dado'
);

select * from finish();
rollback;

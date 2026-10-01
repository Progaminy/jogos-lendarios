begin;

update public.jl_aviator_rounds
   set status='CANCELLED',
       settled_at=coalesce(settled_at,now())
 where status in ('OPEN','LOCKED','FLYING','CRASHED');

update public.jl_aviator_settings
   set enabled=true,
       one_round_test=true,
       updated_at=clock_timestamp()
 where id=true;

do $oneround$
declare
  v_round bigint;
  v_tick jsonb;
  v_enabled boolean;
  v_test boolean;
  v_status text;
begin
  insert into public.jl_aviator_rounds(
    status,
    betting_closes_at,
    takeoff_at
  )
  values(
    'OPEN',
    clock_timestamp()-interval '4 seconds',
    clock_timestamp()+interval '3 seconds'
  )
  returning id into v_round;

  v_tick:=public.jl_process_game_engine_tick()->'aviator';

  if coalesce(v_tick->>'action','')<>'LOCKED'
     or coalesce(v_tick->>'status','')<>'LOCKED' then
    raise exception 'one-round test deveria entrar LOCKED primeiro: %',v_tick;
  end if;

  update public.jl_aviator_rounds
     set takeoff_at=clock_timestamp()-interval '1 second',
         engine_due_at=clock_timestamp()-interval '1 second'
   where id=v_round;

  v_tick:=public.jl_process_game_engine_tick()->'aviator';

  if coalesce(v_tick->>'action','')<>'STARTED'
     or coalesce(v_tick->>'status','')<>'FLYING' then
    raise exception 'one-round test nao iniciou FLYING: %',v_tick;
  end if;

  update public.jl_aviator_rounds
     set started_at=clock_timestamp()-interval '200 seconds',
         engine_due_at=clock_timestamp()-interval '1 second'
   where id=v_round;

  v_tick:=public.jl_process_game_engine_tick()->'aviator';

  if coalesce(v_tick->>'status','')<>'CRASHED'
     or coalesce(v_tick->>'phase','')<>'CRASHED' then
    raise exception 'one-round test deveria commit CRASHED antes de SETTLED: %',v_tick;
  end if;

  select status into v_status
  from public.jl_aviator_rounds
  where id=v_round;

  if v_status<>'CRASHED' then
    raise exception 'rodada deveria permanecer CRASHED por um tick: %',v_status;
  end if;

  v_tick:=public.jl_process_game_engine_tick()->'aviator';

  select enabled,one_round_test
    into v_enabled,v_test
  from public.jl_aviator_settings
  where id=true;

  select status into v_status
  from public.jl_aviator_rounds
  where id=v_round;

  if v_status<>'SETTLED' then
    raise exception 'rodada de teste nao terminou SETTLED: %',v_status;
  end if;

  if coalesce((v_tick->>'maintenance')::boolean,false) is distinct from true then
    raise exception 'tick final deve reportar maintenance=true: %',v_tick;
  end if;

  if v_enabled or v_test then
    raise exception 'one-round test nao voltou para manutencao: enabled %, flag %',
      v_enabled,v_test;
  end if;

  v_tick:=public.jl_process_game_engine_tick()->'aviator';

  if coalesce((v_tick->>'opened')::boolean,false) then
    raise exception 'cron abriu segunda rodada depois do one-round test: %',v_tick;
  end if;
  if position(
    '''engine_test'',v_preflight'
    in (
      select pg_get_functiondef(p.oid)
      from pg_proc p
      join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public'
        and p.proname='jl_aviator_admin_start_one_round_test'
        and pg_get_function_identity_arguments(p.oid)='p_token text'
    )
  )=0 then
    raise exception 'rodada única deve retornar engine_test aprovado';
  end if;
end
$oneround$;

rollback;

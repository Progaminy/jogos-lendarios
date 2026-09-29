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

do $$
declare
  v_round bigint;
  v_tick jsonb;
  v_enabled boolean;
  v_test boolean;
  v_status text;
begin
  insert into public.jl_aviator_rounds(status,betting_closes_at)
  values('OPEN',clock_timestamp()-interval '1 second')
  returning id into v_round;

  v_tick:=public.jl_process_game_engine_tick()->'aviator';

  if v_tick->>'action'<>'STARTED' then
    raise exception 'one-round test nao iniciou: %',v_tick;
  end if;

  update public.jl_aviator_rounds
     set started_at=clock_timestamp()-interval '200 seconds'
   where id=v_round;

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
end
$$;

rollback;

begin;

update public.jl_aviator_rounds
   set status='CANCELLED',
       settled_at=coalesce(settled_at,now())
 where status in ('OPEN','LOCKED','FLYING','CRASHED');

update public.jl_aviator_settings
   set enabled=true,
       updated_at=now()
 where id=true;

do $$
declare
  v_round_id bigint;
  v_tick jsonb;
  v_status text;
  v_started timestamptz;
  v_ceiling numeric;
  v_visual numeric;
begin
  insert into public.jl_aviator_rounds(
    status,
    locked_at,
    takeoff_at,
    total_staked,
    financial_ceiling,
    visual_target,
    effective_target,
    visual_extension
  )
  values(
    'LOCKED',
    clock_timestamp()-interval '4 seconds',
    clock_timestamp()-interval '1 second',
    10,
    1.75,
    20,
    1.75,
    false
  )
  returning id into v_round_id;

  v_tick:=public.jl_process_game_engine_tick()->'aviator';

  if v_tick->>'action'<>'STARTED'
     or v_tick->>'status'<>'FLYING' then
    raise exception 'cron deve recuperar LOCKED atrasado: %',v_tick;
  end if;

  select status,started_at,financial_ceiling,visual_target
    into v_status,v_started,v_ceiling,v_visual
  from public.jl_aviator_rounds
  where id=v_round_id;

  if v_status<>'FLYING' or v_started is null then
    raise exception 'LOCKED nao virou FLYING corretamente';
  end if;

  if v_ceiling<>1.75 or v_visual<>20 then
    raise exception 'recuperacao LOCKED recalculou snapshot/alvo';
  end if;

  update public.jl_aviator_rounds
     set status='CRASHED',
         crashed_at=clock_timestamp(),
         crash_multiplier=1.75
   where id=v_round_id;

  v_tick:=public.jl_process_game_engine_tick()->'aviator';

  if v_tick->>'action'<>'SETTLED'
     or v_tick->>'status'<>'SETTLED' then
    raise exception 'cron deve liquidar CRASHED no tick seguinte: %',v_tick;
  end if;

  select status
    into v_status
  from public.jl_aviator_rounds
  where id=v_round_id;

  if v_status<>'SETTLED' then
    raise exception 'CRASHED nao virou SETTLED; status=%',v_status;
  end if;
end
$$;

rollback;

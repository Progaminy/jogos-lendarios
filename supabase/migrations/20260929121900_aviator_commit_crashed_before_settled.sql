-- Aviator: CRASHED precisa ser um estado realmente observavel/commitado.
-- O tick de voo registra o crash e retorna. Somente o tick seguinte publica/
-- confirma a prova e move a rodada para SETTLED.

create or replace function public.jl_aviator_engine_tick()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  r public.jl_aviator_rounds;
  result jsonb;
  v_enabled boolean:=true;
  v_active int:=0;
  v_one_round_test boolean:=false;
  v_now timestamptz:=clock_timestamp();
  v_takeoff_at timestamptz;
  v_seconds_to_takeoff integer;
begin
  perform pg_advisory_xact_lock(hashtext('jl_aviator_engine_tick'));
  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));

  select coalesce(enabled,true),coalesce(one_round_test,false)
    into v_enabled,v_one_round_test
  from public.jl_aviator_settings
  where id=true;

  select *
    into r
  from public.jl_aviator_rounds
  where status in ('OPEN','LOCKED','FLYING','CRASHED')
  order by id desc
  limit 1
  for update;

  if r.id is null then
    if not v_enabled then
      return jsonb_build_object('action','WAIT','maintenance',true);
    end if;
    return public.jl_aviator_open_next_if_due();
  end if;

  if r.status='OPEN' then
    select count(*)
      into v_active
    from public.jl_aviator_bets
    where round_id=r.id
      and status='ACTIVE';

    if not v_enabled and v_active=0 then
      update public.jl_aviator_rounds
         set status='CANCELLED',
             settled_at=coalesce(settled_at,v_now)
       where id=r.id;

      return jsonb_build_object(
        'action','CANCELLED_EMPTY_OPEN',
        'round_id',r.id,
        'maintenance',true
      );
    end if;

    if r.betting_closes_at is not null
       and v_now>=r.betting_closes_at then
      perform public.jl_aviator_lock_round(r.id);

      return jsonb_build_object(
        'action','LOCKED',
        'round_id',r.id,
        'status','LOCKED',
        'phase','LOCKED',
        'takeoff_at',coalesce(r.takeoff_at,v_now+interval '3 seconds'),
        'maintenance',not v_enabled,
        'one_round_test',v_one_round_test
      );
    end if;

    return jsonb_build_object(
      'action','WAIT',
      'round_id',r.id,
      'status',r.status,
      'phase','BETTING',
      'maintenance',not v_enabled,
      'one_round_test',v_one_round_test
    );
  end if;

  if r.status='LOCKED' then
    v_takeoff_at:=coalesce(
      r.takeoff_at,
      r.locked_at+interval '3 seconds',
      v_now
    );

    if v_now<v_takeoff_at then
      v_seconds_to_takeoff:=greatest(
        0,
        ceil(extract(epoch from (v_takeoff_at-v_now)))
      )::integer;

      return jsonb_build_object(
        'action','WAIT_LOCKED',
        'round_id',r.id,
        'status','LOCKED',
        'phase','LOCKED',
        'seconds_to_takeoff',v_seconds_to_takeoff,
        'takeoff_at',v_takeoff_at,
        'maintenance',not v_enabled,
        'one_round_test',v_one_round_test
      );
    end if;

    r:=public.jl_aviator_start_round(r.id);

    return jsonb_build_object(
      'action','STARTED',
      'round_id',r.id,
      'status','FLYING',
      'phase','FLYING',
      'started_at',r.started_at,
      'maintenance',not v_enabled,
      'one_round_test',v_one_round_test
    );
  end if;

  if r.status='FLYING' then
    result:=public.jl_aviator_tick(r.id);

    if result->>'status'='CRASHED' then
      perform public.jl_aviator_publish_proof(r.id);

      -- Importante: NAO liquidar aqui. CRASHED fica commitado e visivel
      -- ate o proximo engine tick.
      return result || jsonb_build_object(
        'action','CRASHED',
        'phase','CRASHED',
        'maintenance',v_one_round_test or not v_enabled,
        'one_round_test',v_one_round_test
      );
    end if;

    return result || jsonb_build_object(
      'maintenance',v_one_round_test or not v_enabled
    );
  end if;

  if r.status='CRASHED' then
    perform public.jl_aviator_publish_proof(r.id);

    update public.jl_aviator_rounds
       set status='SETTLED',
           settled_at=coalesce(settled_at,now()),
           next_round_at=coalesce(next_round_at,now()+interval '4 seconds')
     where id=r.id
     returning * into r;

    if v_one_round_test then
      update public.jl_aviator_settings
         set enabled=false,
             one_round_test=false,
             updated_at=clock_timestamp()
       where id=true;

      insert into public.audit_log(action,details)
      values(
        'aviator.one_round_test_finished',
        jsonb_build_object('roundId',r.id,'finishedAt',clock_timestamp())
      );
    end if;

    return jsonb_build_object(
      'action','SETTLED',
      'round_id',r.id,
      'status',r.status,
      'phase','SETTLED',
      'maintenance',v_one_round_test or not v_enabled,
      'auto_maintenance',v_one_round_test,
      'one_round_test',false
    );
  end if;

  return jsonb_build_object(
    'action','WAIT',
    'round_id',r.id,
    'status',r.status,
    'phase',case when r.status='OPEN' then 'BETTING' else r.status end,
    'maintenance',not v_enabled,
    'one_round_test',v_one_round_test
  );
end
$$;

revoke all on function public.jl_aviator_engine_tick()
from public,anon,authenticated;
grant execute on function public.jl_aviator_engine_tick()
to service_role;

-- Aviator: auto-recuperacao do ciclo real executado pelo cron.
-- 1. O agregador global acorda o Aviator quando a ultima rodada e CANCELLED.
-- 2. LOCKED persistente e retomado como FLYING sem recalcular snapshot/alvos.
-- 3. CRASHED persistente publica a prova e e finalizado como SETTLED.

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
begin
  perform pg_advisory_xact_lock(hashtext('jl_aviator_engine_tick'));
  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));

  select coalesce(enabled,true)
    into v_enabled
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
             settled_at=coalesce(settled_at,now())
       where id=r.id;

      return jsonb_build_object(
        'action','CANCELLED_EMPTY_OPEN',
        'round_id',r.id,
        'maintenance',true
      );
    end if;

    if r.betting_closes_at is not null and now()>=r.betting_closes_at then
      perform public.jl_aviator_lock_round(r.id);

      update public.jl_aviator_rounds
         set status='FLYING',
             started_at=clock_timestamp()
       where id=r.id;

      return jsonb_build_object(
        'action','STARTED',
        'round_id',r.id,
        'maintenance',not v_enabled
      );
    end if;

    return jsonb_build_object(
      'action','WAIT',
      'round_id',r.id,
      'status',r.status,
      'maintenance',not v_enabled
    );
  end if;

  if r.status='LOCKED' then
    update public.jl_aviator_rounds
       set status='FLYING',
           started_at=coalesce(started_at,clock_timestamp())
     where id=r.id
     returning * into r;

    return jsonb_build_object(
      'action','RECOVERED_LOCKED',
      'round_id',r.id,
      'status',r.status,
      'maintenance',not v_enabled
    );
  end if;

  if r.status='FLYING' then
    result:=public.jl_aviator_tick(r.id);

    if result->>'status'='CRASHED' then
      perform public.jl_aviator_publish_proof(r.id);

      update public.jl_aviator_rounds
         set status='SETTLED',
             settled_at=now(),
             next_round_at=now()+interval '4 seconds'
       where id=r.id;
    end if;

    return result || jsonb_build_object('maintenance',not v_enabled);
  end if;

  if r.status='CRASHED' then
    perform public.jl_aviator_publish_proof(r.id);

    update public.jl_aviator_rounds
       set status='SETTLED',
           settled_at=coalesce(settled_at,now()),
           next_round_at=coalesce(next_round_at,now()+interval '4 seconds')
     where id=r.id
     returning * into r;

    return jsonb_build_object(
      'action','RECOVERED_CRASHED',
      'round_id',r.id,
      'status',r.status,
      'maintenance',not v_enabled
    );
  end if;

  return jsonb_build_object(
    'action','WAIT',
    'round_id',r.id,
    'status',r.status,
    'maintenance',not v_enabled
  );
end
$$;

revoke all on function public.jl_aviator_engine_tick()
from public,anon,authenticated;

grant execute on function public.jl_aviator_engine_tick()
to service_role;

create or replace function public.jl_process_game_engine_tick()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_need_work boolean:=false;
  v_aviator_need boolean:=false;
  v_aviator_enabled boolean:=true;
  v_main jsonb;
  v_aviator jsonb;
begin
  select exists(
    select 1
    from public.game_rounds
    where status in ('open','locked','closed')
      and ((status='open' and closes_at<=now()) or draw_at<=now())
  )
  or exists(
    select 1
    from public.draw_schedule ds
    join public.game_settings gs
      on gs.game_type=ds.game_type and gs.enabled
    where ds.status='pending'
      and not exists(
        select 1
        from public.game_rounds gr
        where gr.game_type=ds.game_type
          and gr.status in ('open','locked','closed','drawn')
      )
  )
  into v_need_work;

  select coalesce(enabled,true)
    into v_aviator_enabled
  from public.jl_aviator_settings
  where id=true;

  select
    exists(
      select 1
      from public.jl_aviator_rounds
      where (status='OPEN' and betting_closes_at<=now())
         or status in ('LOCKED','FLYING','CRASHED')
    )
    or (
      v_aviator_enabled
      and (
        not exists(select 1 from public.jl_aviator_rounds)
        or exists(
          select 1
          from (
            select status,next_round_at
            from public.jl_aviator_rounds
            order by id desc
            limit 1
          ) latest
          where latest.status='CANCELLED'
             or (
               latest.status='SETTLED'
               and coalesce(latest.next_round_at,now())<=now()
             )
        )
      )
    )
  into v_aviator_need;

  if v_need_work then
    v_main:=public.jl_process_game_engine();
  else
    v_main:=jsonb_build_object('idle',true);
  end if;

  if v_aviator_need then
    v_aviator:=public.jl_aviator_engine_tick();
  else
    v_aviator:=jsonb_build_object(
      'idle',true,
      'maintenance',not v_aviator_enabled
    );
  end if;

  return jsonb_build_object(
    'main',v_main,
    'aviator',v_aviator,
    'processed_at',now()
  );
end
$$;

revoke all on function public.jl_process_game_engine_tick()
from public,anon,authenticated;

grant execute on function public.jl_process_game_engine_tick()
to service_role;

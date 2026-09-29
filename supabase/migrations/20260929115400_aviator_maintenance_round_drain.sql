-- Aviator: comportamento deterministico ao entrar em manutencao.
-- OPEN sem apostas e cancelada.
-- OPEN com aposta ja aceite continua ate voo/liquidacao.
-- FLYING nunca e interrompida.
-- Nenhuma nova rodada abre enquanto enabled=false.

create or replace function public.jl_aviator_admin_set_enabled(
  p_token text,
  p_enabled boolean
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  s public.jl_aviator_settings;
  v_cancelled bigint:=0;
begin
  perform public.jl_require_admin(p_token);

  if p_enabled is null then
    raise exception 'Estado de manutencao invalido.';
  end if;

  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));

  insert into public.jl_aviator_settings(id,enabled,updated_at)
  values(true,p_enabled,now())
  on conflict(id) do update
    set enabled=excluded.enabled,
        updated_at=excluded.updated_at
  returning * into s;

  if not p_enabled then
    update public.jl_aviator_rounds r
       set status='CANCELLED',
           settled_at=coalesce(r.settled_at,now())
     where r.status='OPEN'
       and not exists(
         select 1
           from public.jl_aviator_bets b
          where b.round_id=r.id
            and b.status='ACTIVE'
       );

    get diagnostics v_cancelled = row_count;
  end if;

  insert into public.audit_log(action,details)
  values(
    'aviator.maintenance_changed',
    jsonb_build_object(
      'enabled',s.enabled,
      'updatedAt',s.updated_at,
      'emptyOpenRoundsCancelled',v_cancelled
    )
  );

  return jsonb_build_object(
    'ok',true,
    'enabled',s.enabled,
    'maintenance_message',s.maintenance_message,
    'empty_open_rounds_cancelled',v_cancelled
  );
end
$$;

revoke all on function public.jl_aviator_admin_set_enabled(text,boolean) from public;
grant execute on function public.jl_aviator_admin_set_enabled(text,boolean) to anon,authenticated;

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
   where status in ('OPEN','LOCKED','FLYING')
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

  return jsonb_build_object(
    'action','WAIT',
    'round_id',r.id,
    'status',r.status,
    'maintenance',not v_enabled
  );
end
$$;

revoke all on function public.jl_aviator_engine_tick() from public,anon,authenticated;
grant execute on function public.jl_aviator_engine_tick() to service_role;

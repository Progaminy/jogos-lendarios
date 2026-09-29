-- Aviator: janela explicita de bloqueio antes da descolagem.
-- Ciclo publico: BETTING -> LOCKED -> FLYING -> CRASHED -> SETTLED.
-- Internamente OPEN continua representando BETTING para compatibilidade
-- com migrations/RPCs existentes. Novas apostas fecham 3 segundos antes
-- da descolagem e o relogio do servidor e a unica autoridade.

alter table public.jl_aviator_rounds
  add column if not exists takeoff_at timestamptz;

alter table public.jl_aviator_rounds
  drop constraint if exists jl_aviator_rounds_takeoff_after_betting_check;

alter table public.jl_aviator_rounds
  add constraint jl_aviator_rounds_takeoff_after_betting_check
  check (
    takeoff_at is null
    or betting_closes_at is null
    or takeoff_at >= betting_closes_at
  );

create or replace function public.jl_aviator_open_next_if_due()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  r public.jl_aviator_rounds;
  v_enabled boolean;
  v_commit text;
  v_now timestamptz:=clock_timestamp();
begin
  perform pg_advisory_xact_lock(hashtext('jl_aviator_engine_tick'));
  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));

  select enabled
    into v_enabled
  from public.jl_aviator_settings
  where id=true;

  if coalesce(v_enabled,true)=false then
    return jsonb_build_object('opened',false,'maintenance',true);
  end if;

  if exists(
    select 1
    from public.jl_aviator_rounds
    where status in ('OPEN','LOCKED','FLYING')
  ) then
    return jsonb_build_object('opened',false);
  end if;

  select *
    into r
  from public.jl_aviator_rounds
  order by id desc
  limit 1;

  if r.id is null
     or r.status='CANCELLED'
     or (
       r.status='SETTLED'
       and coalesce(r.next_round_at,v_now)<=v_now
     ) then
    insert into public.jl_aviator_rounds(
      status,
      betting_closes_at,
      takeoff_at
    )
    values(
      'OPEN',
      v_now+interval '9 seconds',
      v_now+interval '12 seconds'
    )
    returning * into r;

    v_commit:=public.jl_aviator_prepare_fairness(r.id);

    return jsonb_build_object(
      'opened',true,
      'round_id',r.id,
      'phase','BETTING',
      'betting_closes_at',r.betting_closes_at,
      'takeoff_at',r.takeoff_at,
      'seed_commit',v_commit,
      'fairness_version','JL-AVIATOR-PF-v2'
    );
  end if;

  return jsonb_build_object('opened',false);
end
$$;

create or replace function public.jl_aviator_start_round(p_round_id bigint)
returns public.jl_aviator_rounds
language plpgsql
security definer
set search_path=public
as $$
declare
  v public.jl_aviator_rounds;
  v_takeoff_at timestamptz;
  v_now timestamptz:=clock_timestamp();
begin
  select *
    into v
  from public.jl_aviator_rounds
  where id=p_round_id
  for update;

  if v.id is null or v.status<>'LOCKED' then
    raise exception 'Rodada nao esta LOCKED';
  end if;

  v_takeoff_at:=coalesce(
    v.takeoff_at,
    v.locked_at+interval '3 seconds',
    v_now
  );

  if v_now<v_takeoff_at then
    raise exception 'Rodada ainda esta LOCKED aguardando descolagem';
  end if;

  update public.jl_aviator_rounds
     set status='FLYING',
         started_at=v_now,
         takeoff_at=coalesce(takeoff_at,v_takeoff_at)
   where id=p_round_id
  returning * into v;

  return v;
end
$$;

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

      update public.jl_aviator_rounds
         set status='SETTLED',
             settled_at=now(),
             next_round_at=now()+interval '4 seconds'
       where id=r.id;

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

        result:=result||jsonb_build_object(
          'auto_maintenance',true,
          'one_round_test',false
        );
      end if;
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
      'action','RECOVERED_CRASHED',
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

create or replace function public.jl_aviator_public_state()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  r record;
  s record;
  v_now timestamptz:=clock_timestamp();
  v_frame_ms integer:=250;
  v_display_seq bigint;
  v_display_at timestamptz;
  v_public_status text;
  v_phase text;
  v_public_crash numeric;
  v_target numeric;
  v_exact_multiplier numeric:=1;
  v_current_multiplier numeric:=1;
  v_seconds_to_close integer;
  v_seconds_to_takeoff integer;
  v_takeoff_at timestamptz;
begin
  v_display_seq:=public.jl_aviator_display_seq(v_now,v_frame_ms);
  v_display_at:=
    timestamptz 'epoch'
    + (v_display_seq * v_frame_ms) * interval '1 millisecond';

  select enabled,maintenance_message
    into s
  from public.jl_aviator_settings
  where id=true;

  select
    id,
    status,
    opened_at,
    betting_closes_at,
    takeoff_at,
    locked_at,
    started_at,
    crashed_at,
    settled_at,
    crash_multiplier,
    visual_extension,
    visual_seed_commit,
    visual_seed_reveal,
    round_seed_commit,
    round_seed_reveal,
    lock_proof_commit,
    fairness_version,
    proof_published_at,
    effective_target,
    financial_ceiling,
    visual_target
  into r
  from public.jl_aviator_rounds
  order by id desc
  limit 1;

  if r.id is null then
    return jsonb_build_object(
      'server_time',v_now,
      'display_at',v_display_at,
      'display_seq',v_display_seq,
      'display_frame_ms',v_frame_ms,
      'enabled',coalesce(s.enabled,true),
      'maintenance_message',coalesce(
        s.maintenance_message,
        'Aviator em manutencao. Volte em breve.'
      ),
      'round',null
    );
  end if;

  v_public_status:=r.status;
  v_public_crash:=r.crash_multiplier;
  v_takeoff_at:=coalesce(
    r.takeoff_at,
    case
      when r.locked_at is not null then r.locked_at+interval '3 seconds'
      else null
    end
  );

  if r.status='OPEN' and r.betting_closes_at is not null then
    v_seconds_to_close:=greatest(
      0,
      ceil(extract(epoch from (r.betting_closes_at-v_display_at)))
    )::integer;
  else
    v_seconds_to_close:=null;
  end if;

  if r.status in ('OPEN','LOCKED') and v_takeoff_at is not null then
    v_seconds_to_takeoff:=greatest(
      0,
      ceil(extract(epoch from (v_takeoff_at-v_display_at)))
    )::integer;
  else
    v_seconds_to_takeoff:=null;
  end if;

  if r.status='FLYING' and r.started_at is not null then
    v_target:=coalesce(
      r.effective_target,
      r.financial_ceiling,
      r.visual_target
    );

    v_exact_multiplier:=public.jl_aviator_multiplier(r.started_at,v_now);

    if v_target is not null and v_exact_multiplier>=v_target then
      v_public_status:='CRASHED';
      v_public_crash:=v_target;
      v_current_multiplier:=v_target;
    else
      v_current_multiplier:=public.jl_aviator_multiplier(
        r.started_at,
        greatest(v_display_at,r.started_at)
      );
    end if;
  elsif r.status in ('CRASHED','SETTLED') then
    v_current_multiplier:=greatest(1,coalesce(r.crash_multiplier,1));
  else
    v_current_multiplier:=1;
  end if;

  v_phase:=case
    when v_public_status='OPEN' then 'BETTING'
    else v_public_status
  end;

  return jsonb_build_object(
    'server_time',v_now,
    'display_at',v_display_at,
    'display_seq',v_display_seq,
    'display_frame_ms',v_frame_ms,
    'enabled',coalesce(s.enabled,true),
    'maintenance_message',coalesce(
      s.maintenance_message,
      'Aviator em manutencao. Volte em breve.'
    ),
    'round',jsonb_build_object(
      'id',r.id,
      'status',v_public_status,
      'phase',v_phase,
      'display_seq',v_display_seq,
      'display_at',v_display_at,
      'opened_at',r.opened_at,
      'betting_closes_at',r.betting_closes_at,
      'seconds_to_close',v_seconds_to_close,
      'locked_at',r.locked_at,
      'takeoff_at',v_takeoff_at,
      'seconds_to_takeoff',v_seconds_to_takeoff,
      'betting_open',
        r.status='OPEN'
        and r.betting_closes_at is not null
        and v_display_at<r.betting_closes_at,
      'started_at',r.started_at,
      'current_multiplier',v_current_multiplier,
      'crashed_at',r.crashed_at,
      'settled_at',r.settled_at,
      'crash_multiplier',v_public_crash,
      'visual_extension',r.visual_extension,
      'fairness_version',r.fairness_version,
      'round_seed_commit',coalesce(
        r.round_seed_commit,
        r.visual_seed_commit
      ),
      'lock_proof_commit',r.lock_proof_commit,
      'proof_published_at',r.proof_published_at,
      'round_seed_reveal',
        case
          when r.status in ('CRASHED','SETTLED')
            then coalesce(r.round_seed_reveal,r.visual_seed_reveal)
          else null
        end,
      'visual_seed_commit',coalesce(
        r.round_seed_commit,
        r.visual_seed_commit
      ),
      'visual_seed_reveal',
        case
          when r.status in ('CRASHED','SETTLED')
            then coalesce(r.round_seed_reveal,r.visual_seed_reveal)
          else null
        end
    )
  );
end
$$;

revoke all on function public.jl_aviator_open_next_if_due()
from public,anon,authenticated;
grant execute on function public.jl_aviator_open_next_if_due()
to service_role;

revoke all on function public.jl_aviator_start_round(bigint)
from public,anon,authenticated;
grant execute on function public.jl_aviator_start_round(bigint)
to service_role;

revoke all on function public.jl_aviator_engine_tick()
from public,anon,authenticated;
grant execute on function public.jl_aviator_engine_tick()
to service_role;

revoke all on function public.jl_aviator_public_state() from public;
grant execute on function public.jl_aviator_public_state()
to anon,authenticated,service_role;

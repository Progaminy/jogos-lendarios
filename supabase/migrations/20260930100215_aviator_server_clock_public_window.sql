
alter table public.jl_aviator_bets
  alter column created_at set default clock_timestamp();

create or replace function public.jl_aviator_public_state()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
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
    round_no,
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
      'round_no',r.round_no,
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
        and v_now<r.betting_closes_at,
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
$function$;

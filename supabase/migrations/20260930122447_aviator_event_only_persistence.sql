
alter table public.audit_log
  drop constraint if exists audit_log_no_aviator_visual_noise;

alter table public.audit_log
  add constraint audit_log_no_aviator_visual_noise
  check (
    action !~* '^aviator\.(frame|tick|render|heartbeat|multiplier_frame|multiplier_update|visual_frame)([._]|$)'
  );

create or replace function public.jl_aviator_schedule_next_engine_event(
  p_round_id bigint
)
returns timestamptz
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_round public.jl_aviator_rounds;
  v_target numeric;
  v_auto numeric;
  v_next_multiplier numeric;
  v_due timestamptz;
begin
  select *
    into v_round
  from public.jl_aviator_rounds
  where id=p_round_id
  for update;

  if v_round.id is null then
    return null;
  end if;

  case v_round.status
    when 'OPEN' then
      v_due:=v_round.betting_closes_at;
    when 'LOCKED' then
      v_due:=coalesce(
        v_round.takeoff_at,
        v_round.locked_at+interval '3 seconds',
        clock_timestamp()
      );
    when 'FLYING' then
      v_target:=coalesce(
        v_round.effective_target,
        v_round.financial_ceiling,
        v_round.visual_target
      );

      if v_round.started_at is null or v_target is null then
        v_due:=clock_timestamp();
      else
        select min(b.auto_cashout_multiplier)
          into v_auto
        from public.jl_aviator_bets b
        where b.round_id=p_round_id
          and b.status='ACTIVE'
          and b.auto_cashout_multiplier is not null
          and b.auto_cashout_multiplier<v_target;

        v_next_multiplier:=case
          when v_auto is null then v_target
          else least(v_auto,v_target)
        end;

        v_due:=public.jl_aviator_multiplier_reach_at(
          v_round.started_at,
          v_next_multiplier
        );
      end if;
    when 'CRASHED' then
      v_due:=clock_timestamp();
    else
      v_due:=null;
  end case;

  update public.jl_aviator_rounds
     set engine_due_at=v_due
   where id=p_round_id
     and engine_due_at is distinct from v_due;

  return v_due;
end;
$function$;

create or replace function public.jl_cron_prune_history()
returns integer
language plpgsql
security definer
set search_path to 'cron','public'
as $function$
declare
  v_deleted integer:=0;
  v_engine_jobid bigint;
begin
  select jobid
    into v_engine_jobid
  from cron.job
  where jobname='jogos_lendarios_engine'
  limit 1;

  delete from cron.job_run_details d
  where
    (
      d.status='succeeded'
      and d.jobid=v_engine_jobid
      and coalesce(d.end_time,d.start_time)<clock_timestamp()-interval '2 hours'
    )
    or
    (
      d.status='succeeded'
      and d.jobid is distinct from v_engine_jobid
      and coalesce(d.end_time,d.start_time)<clock_timestamp()-interval '48 hours'
    )
    or
    (
      coalesce(d.status,'')<>'succeeded'
      and d.start_time<clock_timestamp()-interval '30 days'
    );

  get diagnostics v_deleted=row_count;
  return v_deleted;
end;
$function$;

comment on constraint audit_log_no_aviator_visual_noise on public.audit_log is
  'Aviator persists business events only; visual frames/ticks/multiplier refreshes must never enter durable audit history.';

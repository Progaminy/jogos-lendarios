
create table if not exists public.ludo_events_archive (
  id bigint primary key,
  room_id uuid not null,
  player_id uuid,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null,
  archived_at timestamptz not null default now()
);

create index if not exists ludo_events_archive_room_idx
  on public.ludo_events_archive(room_id,id desc);

create index if not exists ludo_events_archive_created_idx
  on public.ludo_events_archive(created_at desc);

alter table public.ludo_events_archive enable row level security;

revoke all on table public.ludo_events_archive from public, anon, authenticated;
grant all on table public.ludo_events_archive to service_role;

create or replace function public.jl_ludo_data_retention_maintenance(
  p_hot_days integer default 90,
  p_batch_limit integer default 5000
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_cutoff timestamptz;
  v_inserted integer:=0;
  v_removed integer:=0;
  v_signals integer:=0;
  v_limit integer:=least(greatest(coalesce(p_batch_limit,5000),100),20000);
begin
  v_cutoff:=now()-make_interval(days=>greatest(coalesce(p_hot_days,90),30));

  insert into public.ludo_events_archive(
    id,room_id,player_id,event_type,payload,created_at,archived_at
  )
  select
    e.id,e.room_id,e.player_id,e.event_type,e.payload,e.created_at,now()
  from public.ludo_events e
  join public.ludo_rooms r on r.id=e.room_id
  where r.status in ('finished','cancelled')
    and e.created_at<v_cutoff
  order by e.id
  limit v_limit
  on conflict(id) do nothing;
  get diagnostics v_inserted=row_count;

  delete from public.ludo_events e
  where e.id in (
    select e2.id
    from public.ludo_events e2
    join public.ludo_rooms r on r.id=e2.room_id
    join public.ludo_events_archive a on a.id=e2.id
    where r.status in ('finished','cancelled')
      and e2.created_at<v_cutoff
    order by e2.id
    limit v_limit
  );
  get diagnostics v_removed=row_count;

  delete from public.ludo_signals
  where expires_at<=now();
  get diagnostics v_signals=row_count;

  return jsonb_build_object(
    'ok',true,
    'hot_days',greatest(coalesce(p_hot_days,90),30),
    'cutoff',v_cutoff,
    'events_archived',v_inserted,
    'events_removed_from_hot',v_removed,
    'expired_signals_removed',v_signals
  );
end;
$function$;

revoke all on function public.jl_ludo_data_retention_maintenance(integer,integer) from public;
revoke all on function public.jl_ludo_data_retention_maintenance(integer,integer) from anon,authenticated;
grant execute on function public.jl_ludo_data_retention_maintenance(integer,integer) to service_role;

do $$
declare
  v_jobid bigint;
begin
  select jobid into v_jobid
  from cron.job
  where jobname='jogos_lendarios_ludo_data_retention'
  limit 1;

  if v_jobid is not null then
    perform cron.unschedule(v_jobid);
  end if;

  perform cron.schedule(
    'jogos_lendarios_ludo_data_retention',
    '37 * * * *',
    'select public.jl_ludo_data_retention_maintenance(90,5000);'
  );
end
$$;

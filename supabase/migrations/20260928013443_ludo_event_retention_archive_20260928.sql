create table if not exists public.ludo_events_archive (
  id bigint primary key,
  room_id uuid not null,
  player_id uuid,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null,
  archived_at timestamptz not null default now()
);

alter table public.ludo_events_archive enable row level security;

revoke all on table public.ludo_events_archive from public, anon, authenticated;
grant select on table public.ludo_events_archive to service_role;

create index if not exists ludo_events_created_at_idx
  on public.ludo_events (created_at, room_id);

create index if not exists ludo_events_archive_room_idx
  on public.ludo_events_archive (room_id, id desc);

create index if not exists ludo_events_archive_player_idx
  on public.ludo_events_archive (player_id);

create index if not exists ludo_events_archive_created_at_idx
  on public.ludo_events_archive (created_at desc);

create or replace function public.jl_ludo_retention_cleanup()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_archived integer:=0;
  v_signals integer:=0;
begin
  delete from public.ludo_signals
  where expires_at<=now();
  get diagnostics v_signals=row_count;

  with candidates as (
    select e.id
    from public.ludo_events e
    join public.ludo_rooms r on r.id=e.room_id
    where r.status in ('finished','cancelled')
      and e.created_at<now()-interval '90 days'
    order by e.created_at,e.id
    limit 5000
    for update of e skip locked
  ),
  moved as (
    delete from public.ludo_events e
    using candidates c
    where e.id=c.id
    returning e.id,e.room_id,e.player_id,e.event_type,e.payload,e.created_at
  )
  insert into public.ludo_events_archive(
    id,room_id,player_id,event_type,payload,created_at,archived_at
  )
  select id,room_id,player_id,event_type,payload,created_at,now()
  from moved
  on conflict(id) do nothing;

  get diagnostics v_archived=row_count;

  return jsonb_build_object(
    'ok',true,
    'archived_events',v_archived,
    'expired_signals_deleted',v_signals,
    'hot_retention_days',90,
    'batch_limit',5000
  );
end;
$function$;

revoke all on function public.jl_ludo_retention_cleanup() from public, anon, authenticated;
grant execute on function public.jl_ludo_retention_cleanup() to service_role;

do $$
declare
  v_jobid bigint;
begin
  select jobid into v_jobid
  from cron.job
  where jobname='jogos_lendarios_ludo_retention'
  limit 1;

  if v_jobid is not null then
    perform cron.unschedule(v_jobid);
  end if;

  perform cron.schedule(
    'jogos_lendarios_ludo_retention',
    '23 * * * *',
    'select public.jl_ludo_retention_cleanup();'
  );
end
$$;
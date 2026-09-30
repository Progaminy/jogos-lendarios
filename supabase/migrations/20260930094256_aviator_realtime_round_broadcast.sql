
create or replace function public.jl_aviator_realtime_broadcast_state()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_state jsonb;
begin
  v_state:=public.jl_aviator_public_state();

  perform realtime.send(
    v_state,
    'state',
    'aviator:round',
    false
  );

  return null;
end;
$function$;

revoke all on function public.jl_aviator_realtime_broadcast_state()
from public,anon,authenticated;

grant execute on function public.jl_aviator_realtime_broadcast_state()
to service_role;

drop trigger if exists jl_aviator_round_realtime_state
on public.jl_aviator_rounds;

create trigger jl_aviator_round_realtime_state
after insert or update of
  status,
  betting_closes_at,
  takeoff_at,
  locked_at,
  started_at,
  crashed_at,
  settled_at,
  crash_multiplier,
  visual_extension,
  effective_target,
  visual_target,
  round_seed_commit,
  round_seed_reveal,
  visual_seed_commit,
  visual_seed_reveal,
  lock_proof_commit,
  proof_published_at
on public.jl_aviator_rounds
for each row
execute function public.jl_aviator_realtime_broadcast_state();

drop trigger if exists jl_aviator_settings_realtime_state
on public.jl_aviator_settings;

create trigger jl_aviator_settings_realtime_state
after update of enabled,maintenance_message
on public.jl_aviator_settings
for each row
execute function public.jl_aviator_realtime_broadcast_state();

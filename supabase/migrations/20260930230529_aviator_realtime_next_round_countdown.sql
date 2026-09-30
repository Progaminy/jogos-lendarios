
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
  next_round_at,
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

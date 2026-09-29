-- Aviator: funcoes internas nunca devem ser RPCs publicas.
revoke execute on function public.jl_aviator_set_visual_target(bigint,numeric) from public,anon,authenticated;
revoke execute on function public.jl_aviator_reveal_seed(bigint) from public,anon,authenticated;
revoke execute on function public.jl_aviator_publish_proof(bigint) from public,anon,authenticated;
revoke execute on function public.jl_aviator_after_crash(bigint) from public,anon,authenticated;
revoke execute on function public.jl_aviator_cashout_guard(text,bigint) from public,anon,authenticated;
grant execute on function public.jl_aviator_set_visual_target(bigint,numeric) to service_role;
grant execute on function public.jl_aviator_reveal_seed(bigint) to service_role;
grant execute on function public.jl_aviator_publish_proof(bigint) to service_role;
grant execute on function public.jl_aviator_after_crash(bigint) to service_role;
grant execute on function public.jl_aviator_cashout_guard(text,bigint) to service_role;
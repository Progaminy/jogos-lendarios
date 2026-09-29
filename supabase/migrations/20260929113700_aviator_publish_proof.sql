-- Aviator: prova publica somente depois do crash.
create or replace function public.jl_aviator_publish_proof(p_round_id bigint)
returns void language plpgsql security definer set search_path=public
as $$
begin
 update public.jl_aviator_rounds r set visual_seed_reveal=s.seed
 from public.jl_aviator_round_secrets s
 where r.id=p_round_id and s.round_id=p_round_id
   and r.status in ('CRASHED','SETTLED');
end $$;

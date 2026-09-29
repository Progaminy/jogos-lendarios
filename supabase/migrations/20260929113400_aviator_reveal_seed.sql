-- Aviator: revelar a seed somente depois de a rodada terminar.
create or replace function public.jl_aviator_reveal_seed(p_round_id bigint)
returns void language plpgsql security definer set search_path=public
as $$
begin
 update public.jl_aviator_rounds r
 set visual_seed_reveal=s.seed
 from public.jl_aviator_round_secrets s
 where r.id=p_round_id and s.round_id=r.id and r.status in ('CRASHED','SETTLED');
end $$;

-- Aviator: integrar publicacao da prova no crash idempotente.
create or replace function public.jl_aviator_after_crash(p_round_id bigint)
returns void language plpgsql security definer set search_path=public
as $$
begin
 perform public.jl_aviator_publish_proof(p_round_id);
end $$;

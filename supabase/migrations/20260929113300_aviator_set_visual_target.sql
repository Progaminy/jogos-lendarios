-- Aviator: guardar o alvo visual final quando a exposicao financeira termina.
create or replace function public.jl_aviator_set_visual_target(p_round_id bigint,p_current numeric)
returns numeric language plpgsql security definer set search_path=public
as $$
declare v_target numeric;
begin
 v_target:=public.jl_aviator_extension_target(p_round_id,p_current);
 update public.jl_aviator_rounds
 set visual_extension=true,zero_exposure_at_multiplier=p_current,
     visual_target=v_target,effective_target=v_target
 where id=p_round_id and status='FLYING';
 return v_target;
end $$;

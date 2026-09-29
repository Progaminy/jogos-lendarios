-- Aviator: extensao sem responsabilidade financeira apos a ultima aposta sair.
create or replace function public.jl_aviator_extension_target(p_round_id bigint,p_current numeric)
returns numeric
language plpgsql security definer
set search_path=public
as $$
declare v_u numeric; v_floor numeric;
begin
  select unit_value into v_u from public.jl_aviator_round_secrets where round_id=p_round_id;
  if v_u is null then raise exception 'Segredo da rodada ausente'; end if;
  v_floor:=greatest(5::numeric,p_current);
  if v_floor>=135.7 then return p_current; end if;
  return round(v_floor+(135.7-v_floor)*v_u,6);
end $$;

revoke all on function public.jl_aviator_extension_target(bigint,numeric) from public,anon,authenticated;
grant execute on function public.jl_aviator_extension_target(bigint,numeric) to service_role;

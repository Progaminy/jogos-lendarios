begin;

update public.jl_aviator_settings
set enabled=false,updated_at=now()
where id=true;

do $$
declare
  v_before bigint;
  v_after bigint;
  v_open jsonb;
  v_state jsonb;
begin
  select count(*) into v_before from public.jl_aviator_rounds;

  v_open:=public.jl_aviator_open_next_if_due();

  select count(*) into v_after from public.jl_aviator_rounds;

  if v_after<>v_before then
    raise exception 'manutencao nao pode abrir nova rodada';
  end if;

  if coalesce((v_open->>'maintenance')::boolean,false) is distinct from true then
    raise exception 'open_next_if_due deve informar manutencao';
  end if;

  v_state:=public.jl_aviator_public_state();

  if coalesce((v_state->>'enabled')::boolean,true) is distinct from false then
    raise exception 'public_state deve refletir enabled=false';
  end if;
end
$$;

rollback;

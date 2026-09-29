begin;

do $$
declare
  v_results jsonb;
  v_len integer;
begin
  v_results:=public.jl_aviator_recent_results(12);

  if jsonb_typeof(v_results)<>'array' then
    raise exception 'historico do Aviator deve ser um array';
  end if;

  v_len:=jsonb_array_length(v_results);
  if v_len>12 then
    raise exception 'historico excedeu o limite pedido: %',v_len;
  end if;

  if exists(
    select 1
    from jsonb_array_elements(v_results) e
    where e ? 'visual_seed_reveal'
       or e ? 'visual_seed_commit'
       or e ? 'effective_target'
       or e ? 'financial_ceiling'
       or e ? 'total_staked'
  ) then
    raise exception 'historico publico expoe campos internos';
  end if;
end
$$;

rollback;

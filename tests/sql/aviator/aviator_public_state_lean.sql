begin;

do $$
declare
  v_def text;
  v_state jsonb;
  v_round jsonb;
begin
  select pg_get_functiondef('public.jl_aviator_public_state()'::regprocedure)
    into v_def;

  if position('count(*)' in lower(v_def))>0 then
    raise exception 'public_state nao deve contar apostas em cada poll';
  end if;

  if position('select *' in lower(v_def))>0 then
    raise exception 'public_state nao deve usar select *';
  end if;

  v_state:=public.jl_aviator_public_state();
  v_round:=v_state->'round';

  if v_state ? 'server_time' is distinct from true then
    raise exception 'server_time ausente';
  end if;

  if v_state ? 'enabled' is distinct from true then
    raise exception 'enabled ausente';
  end if;

  if v_round is not null and jsonb_typeof(v_round)='object' then
    if v_round ? 'financial_ceiling' then
      raise exception 'financial_ceiling nao pode vazar no estado publico';
    end if;

    if v_round ? 'effective_target' then
      raise exception 'effective_target nao pode vazar no estado publico';
    end if;

    if v_round ? 'visual_target' then
      raise exception 'visual_target nao pode vazar no estado publico';
    end if;

    if v_round ? 'active_bets' then
      raise exception 'active_bets removido do contrato publico enxuto';
    end if;
  end if;
end
$$;

rollback;

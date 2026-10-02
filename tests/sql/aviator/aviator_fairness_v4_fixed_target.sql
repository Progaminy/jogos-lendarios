-- Regression: the abandoned PF-v4 admission rule must not block normal betting.
-- Historical v4 helpers remain readable for already-finished rounds, but new
-- rounds use PF-v3 financial-ceiling semantics.
begin;

do $$
declare
  v_target numeric;
  v_legacy numeric;
  v_place_def text;
  v_prepare_def text;
begin
  -- Historical v4 rounds remain reproducible.
  v_target:=public.jl_aviator_operational_target(
    'JL-AVIATOR-PF-v4',
    5.12,
    5.12,
    138.873259
  );

  if round(v_target,6)<>138.873259 then
    raise exception 'historical v4 target semantics changed: %',v_target;
  end if;

  -- Active PF-v3 betting continues to use the frozen financial ceiling.
  v_legacy:=public.jl_aviator_operational_target(
    'JL-AVIATOR-PF-v3',
    5.12,
    5.12,
    138.873259
  );

  if round(v_legacy,6)<>5.120000 then
    raise exception 'PF-v3 financial ceiling semantics changed: %',v_legacy;
  end if;

  select pg_get_functiondef(
    'public.jl_aviator_place_bet_slot(text,numeric,text,numeric,integer)'::regprocedure
  )
  into v_place_def;

  if position('jl_aviator_risk_capacity_' in v_place_def)>0
     or position('Limite seguro da rodada atingido' in v_place_def)>0
     or position('v_required_liability' in v_place_def)>0 then
    raise exception 'regression: PF-v4 full-target admission gate returned';
  end if;

  if position('JL-AVIATOR-PF-v4' in v_place_def)=0
     or position('Rodada em transicao de seguranca' in v_place_def)=0 then
    raise exception 'legacy v4 transition guard is missing';
  end if;

  select pg_get_functiondef(
    'public.jl_aviator_prepare_fairness(bigint)'::regprocedure
  )
  into v_prepare_def;

  if position('JL-AVIATOR-PF-v4' in v_prepare_def)>0 then
    raise exception 'new fairness preparation still creates PF-v4 rounds';
  end if;

  if position('JL-AVIATOR-PF-v3' in v_prepare_def)=0 then
    raise exception 'PF-v3 is not the active fairness version';
  end if;
end
$$;

rollback;

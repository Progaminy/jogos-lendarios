-- Regression: fairness v4 must be independent from financial exposure.
begin;

do $$
declare
  v_target numeric;
  v_legacy numeric;
  v_payload text;
  v_bad bigint;
  v_place_def text;
  v_public_def text;
begin
  v_target:=public.jl_aviator_operational_target(
    'JL-AVIATOR-PF-v4',
    5.12,
    5.12,
    138.873259
  );

  if round(v_target,6)<>138.873259 then
    raise exception 'v4 target followed financial ceiling: %',v_target;
  end if;

  v_legacy:=public.jl_aviator_operational_target(
    'JL-AVIATOR-PF-v3',
    5.12,
    5.12,
    138.873259
  );

  if round(v_legacy,6)<>5.120000 then
    raise exception 'legacy semantics unexpectedly changed: %',v_legacy;
  end if;

  v_payload:=public.jl_aviator_fairness_lock_payload_v4(
    1,
    repeat('a',64),
    0,
    null,
    304.149569,
    304.149569
  );

  if v_payload is null or position('JL-AVIATOR-PF-v4' in v_payload)=0
     or position('|NULL|' in v_payload)=0 then
    raise exception 'v4 no-exposure proof payload invalid: %',v_payload;
  end if;

  select count(*)
    into v_bad
  from public.jl_aviator_rounds
  where fairness_version='JL-AVIATOR-PF-v4'
    and status in ('LOCKED','FLYING','CRASHED','SETTLED')
    and (
      round(locked_effective_target,6)<>round(visual_target,6)
      or round(effective_target,6)<>round(visual_target,6)
      or coalesce(visual_extension,false)
      or effective_target>500
      or locked_effective_target>500
      or (
        total_staked>0
        and (
          financial_ceiling is null
          or financial_ceiling+0.000001<visual_target
        )
      )
    );

  if v_bad>0 then
    raise exception 'found % v4 rounds violating fixed-target invariants',v_bad;
  end if;

  select pg_get_functiondef(p.oid)
    into v_place_def
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='jl_aviator_place_bet_slot';

  if position('jl_aviator_risk_capacity_' in v_place_def)=0
     or position('Limite seguro da rodada atingido' in v_place_def)=0 then
    raise exception 'safe admission guard missing';
  end if;

  select pg_get_functiondef(p.oid)
    into v_public_def
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='jl_aviator_public_state';

  if position('jl_aviator_operational_target' in v_public_def)=0 then
    raise exception 'public state is not using canonical operational target';
  end if;
end
$$;

rollback;

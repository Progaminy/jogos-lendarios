-- Regression: Aviator never exceeds the configured 500x hard cap.
begin;

do $$
declare
  v_long numeric;
  v_min numeric;
  v_max numeric;
  v_name text;
  v_def text;
begin
  v_long:=public.jl_aviator_multiplier(
    clock_timestamp()-interval '200 seconds',
    clock_timestamp()
  );

  if v_long<>500 then
    raise exception 'expected multiplier hard cap 500x, got %',v_long;
  end if;

  v_min:=public.jl_aviator_fairness_visual_target_v3(repeat('0',64));
  v_max:=public.jl_aviator_fairness_visual_target_v3(repeat('f',64));

  if v_min<10 or v_max>500 then
    raise exception 'visual target outside 10x..500x: min %, max %',v_min,v_max;
  end if;

  for v_name,v_def in
    select p.proname,pg_get_functiondef(p.oid)
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in (
        'jl_aviator_multiplier',
        'jl_aviator_set_visual_target',
        'jl_aviator_tick',
        'jl_aviator_cashout_core',
        'jl_aviator_cashout_locked',
        'jl_aviator_process_auto_cashouts',
        'jl_aviator_round_proof'
      )
  loop
    if position('least(500' in replace(v_def,'::numeric',''))=0 then
      raise exception 'missing 500x cap in %',v_name;
    end if;
  end loop;
end
$$;

rollback;

begin;

do $$
declare
  v_signature text;
  v_internal text[]:=array[
    'public.jl_aviator_after_crash(bigint)',
    'public.jl_aviator_cashout_guard(text,bigint)',
    'public.jl_aviator_engine_tick()',
    'public.jl_aviator_extension_target(bigint,numeric)',
    'public.jl_aviator_financial_ceiling(numeric,numeric,numeric)',
    'public.jl_aviator_lock_round(bigint)',
    'public.jl_aviator_multiplier(timestamptz,timestamptz)',
    'public.jl_aviator_open_next_if_due()',
    'public.jl_aviator_publish_proof(bigint)',
    'public.jl_aviator_reveal_seed(bigint)',
    'public.jl_aviator_set_visual_target(bigint,numeric)',
    'public.jl_aviator_start_round(bigint)',
    'public.jl_aviator_tick(bigint)'
  ];
begin
  foreach v_signature in array v_internal loop
    if to_regprocedure(v_signature) is null then
      raise exception 'RPC interna ausente: %',v_signature;
    end if;

    if has_function_privilege('anon',v_signature,'EXECUTE') then
      raise exception 'anon pode executar RPC interna: %',v_signature;
    end if;

    if has_function_privilege('authenticated',v_signature,'EXECUTE') then
      raise exception 'authenticated pode executar RPC interna: %',v_signature;
    end if;

    if not has_function_privilege('service_role',v_signature,'EXECUTE') then
      raise exception 'service_role sem acesso a RPC interna: %',v_signature;
    end if;
  end loop;
end
$$;

rollback;

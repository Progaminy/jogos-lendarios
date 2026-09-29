begin;

do $$
declare
  v_a bigint;
  v_b bigint;
  v_c bigint;
  v_state jsonb;
  v_def text;
begin
  v_a:=public.jl_aviator_display_seq(
    timestamptz '2026-09-29 12:00:00.001+00',
    250
  );
  v_b:=public.jl_aviator_display_seq(
    timestamptz '2026-09-29 12:00:00.249+00',
    250
  );
  v_c:=public.jl_aviator_display_seq(
    timestamptz '2026-09-29 12:00:00.250+00',
    250
  );

  if v_a<>v_b then
    raise exception 'instantes no mesmo frame devem ter o mesmo display_seq';
  end if;

  if v_c<>v_a+1 then
    raise exception 'frame seguinte deve incrementar display_seq em 1';
  end if;

  v_state:=public.jl_aviator_public_state();

  if v_state ? 'display_seq' is distinct from true then
    raise exception 'display_seq ausente do estado publico';
  end if;

  if v_state ? 'display_at' is distinct from true then
    raise exception 'display_at ausente do estado publico';
  end if;

  if (v_state->>'display_frame_ms')::integer<>250 then
    raise exception 'display_frame_ms deve ser 250';
  end if;

  select pg_get_functiondef('public.jl_aviator_public_state()'::regprocedure)
    into v_def;

  if position('greatest(v_display_at,r.started_at)' in replace(lower(v_def),' ',''))=0 then
    raise exception 'multiplicador publico deve usar o frame canonico';
  end if;

  if position('v_exact_multiplier' in lower(v_def))=0 then
    raise exception 'crash logico deve continuar usando o relogio exato';
  end if;
end
$$;

rollback;

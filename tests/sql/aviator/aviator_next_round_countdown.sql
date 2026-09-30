-- Ponto 46: contagem regressiva da próxima rodada vem do relógio do servidor.
begin;

do $test$
declare
  v_round bigint;
  v_state jsonb;
  v_seconds integer;
  v_def text;
begin
  insert into public.jl_aviator_rounds(
    status,
    settled_at,
    next_round_at,
    crash_multiplier
  )
  values(
    'SETTLED',
    clock_timestamp(),
    clock_timestamp()+interval '4 seconds',
    1.50
  )
  returning id into v_round;

  v_state:=public.jl_aviator_public_state();

  if (v_state->'round'->>'id')::bigint<>v_round then
    raise exception 'estado público não retornou rodada de teste';
  end if;

  if v_state->'round'->>'next_round_at' is null then
    raise exception 'next_round_at não está público';
  end if;

  v_seconds:=(v_state->'round'->>'seconds_to_next_round')::integer;

  if v_seconds not between 3 and 4 then
    raise exception 'contagem do servidor inesperada: %',v_seconds;
  end if;

  select pg_get_triggerdef(t.oid)
    into v_def
  from pg_trigger t
  join pg_class c on c.oid=t.tgrelid
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public'
    and c.relname='jl_aviator_rounds'
    and t.tgname='jl_aviator_round_realtime_state'
    and not t.tgisinternal;

  if position('next_round_at' in lower(v_def))=0 then
    raise exception 'Realtime não publica mudança de next_round_at';
  end if;
end
$test$;

rollback;

begin;

update public.jl_aviator_bank
   set balance=60,
       exposure_ratio=.5,
       exposure_cycle_anchor=timestamptz '2026-01-01 00:00:00+00',
       updated_at=clock_timestamp()
 where id=true;

do $cycle$
declare
  s jsonb;
begin
  s:=public.jl_aviator_exposure_cycle_state(
    timestamptz '2026-01-01 00:00:00+00'
  );
  if (s->>'moment')::int<>1 or (s->>'exposure_ratio')::numeric<>.25 then
    raise exception 'momento 1 incorreto: %',s;
  end if;

  s:=public.jl_aviator_exposure_cycle_state(
    timestamptz '2026-01-01 03:29:59+00'
  );
  if (s->>'moment')::int<>1 then
    raise exception 'momento 1 terminou cedo: %',s;
  end if;

  s:=public.jl_aviator_exposure_cycle_state(
    timestamptz '2026-01-01 03:30:00+00'
  );
  if (s->>'moment')::int<>2
     or (s->>'exposure_ratio')::numeric<>.333333 then
    raise exception 'momento 2 incorreto: %',s;
  end if;

  s:=public.jl_aviator_exposure_cycle_state(
    timestamptz '2026-01-01 07:00:00+00'
  );
  if (s->>'moment')::int<>3 or (s->>'exposure_ratio')::numeric<>.5 then
    raise exception 'momento 3 incorreto: %',s;
  end if;

  s:=public.jl_aviator_exposure_cycle_state(
    timestamptz '2026-01-01 10:29:59+00'
  );
  if (s->>'moment')::int<>3 then
    raise exception 'momento 3 terminou cedo: %',s;
  end if;

  s:=public.jl_aviator_exposure_cycle_state(
    timestamptz '2026-01-01 10:30:00+00'
  );
  if (s->>'moment')::int<>1 or (s->>'exposure_ratio')::numeric<>.25 then
    raise exception 'ciclo nao reiniciou no momento 1: %',s;
  end if;
end
$cycle$;

rollback;

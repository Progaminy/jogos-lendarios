begin;

update public.jl_aviator_settings
   set enabled=true,
       one_round_test=false,
       updated_at=clock_timestamp()
 where id=true;

update public.jl_aviator_rounds
   set status='CANCELLED',
       settled_at=coalesce(settled_at,clock_timestamp())
 where status in ('OPEN','LOCKED','FLYING','CRASHED');

do $countdown$
declare
  v_result jsonb;
  r public.jl_aviator_rounds;
  v_open_seconds numeric;
  v_locked_at timestamptz;
  v_wait_seconds numeric;
begin
  v_result:=public.jl_aviator_open_next_if_due();

  if coalesce((v_result->>'opened')::boolean,false) is not true then
    raise exception 'rodada nao abriu: %',v_result;
  end if;

  select * into r
  from public.jl_aviator_rounds
  where id=(v_result->>'round_id')::bigint;

  v_open_seconds:=extract(epoch from (r.betting_closes_at-r.opened_at));
  if v_open_seconds<9.8 or v_open_seconds>10.2 then
    raise exception 'janela de apostas esperada 10s: %',v_open_seconds;
  end if;

  if r.takeoff_at is not null then
    raise exception 'takeoff_at deve ser definido somente depois do lock: %',r.takeoff_at;
  end if;

  update public.jl_aviator_rounds
     set betting_closes_at=clock_timestamp()-interval '1 millisecond',
         engine_due_at=clock_timestamp()-interval '1 millisecond'
   where id=r.id;

  perform public.jl_aviator_engine_tick();

  select locked_at into v_locked_at
  from public.jl_aviator_rounds
  where id=r.id;

  if v_locked_at is null then
    raise exception 'rodada deveria estar LOCKED depois de 0';
  end if;

  v_wait_seconds:=extract(epoch from (
    public.jl_aviator_schedule_next_engine_event(r.id)-v_locked_at
  ));

  if v_wait_seconds<2.8 or v_wait_seconds>3.2 then
    raise exception 'janela de segurança esperada ~3s apos lock: %',v_wait_seconds;
  end if;
end
$countdown$;

rollback;

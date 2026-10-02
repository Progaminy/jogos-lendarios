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
  v_total_seconds numeric;
  v_locked_seconds numeric;
begin
  v_result:=public.jl_aviator_open_next_if_due();

  if coalesce((v_result->>'opened')::boolean,false) is not true then
    raise exception 'rodada nao abriu: %',v_result;
  end if;

  select * into r
  from public.jl_aviator_rounds
  where id=(v_result->>'round_id')::bigint;

  v_open_seconds:=extract(epoch from (r.betting_closes_at-r.opened_at));
  v_total_seconds:=extract(epoch from (r.takeoff_at-r.opened_at));
  v_locked_seconds:=extract(epoch from (r.takeoff_at-r.betting_closes_at));

  if v_open_seconds<6.8 or v_open_seconds>7.2 then
    raise exception 'janela OPEN esperada 7s: %',v_open_seconds;
  end if;

  if v_total_seconds<9.8 or v_total_seconds>10.2 then
    raise exception 'contagem total esperada 10s: %',v_total_seconds;
  end if;

  if v_locked_seconds<2.9 or v_locked_seconds>3.1 then
    raise exception 'janela LOCKED esperada 3s: %',v_locked_seconds;
  end if;
end
$countdown$;

rollback;

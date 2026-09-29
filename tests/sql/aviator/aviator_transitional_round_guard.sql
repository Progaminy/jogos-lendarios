begin;

update public.jl_aviator_rounds
   set status='CANCELLED',
       settled_at=coalesce(settled_at,now())
 where status in ('OPEN','LOCKED','FLYING','CRASHED');

do $$
declare
  v_first bigint;
  v_blocked boolean:=false;
begin
  insert into public.jl_aviator_rounds(status,crash_multiplier,crashed_at)
  values('CRASHED',1.25,clock_timestamp())
  returning id into v_first;

  begin
    insert into public.jl_aviator_rounds(status,betting_closes_at)
    values('OPEN',clock_timestamp()+interval '12 seconds');
  exception
    when unique_violation then
      v_blocked:=true;
  end;

  if not v_blocked then
    raise exception 'deve impedir OPEN coexistindo com CRASHED transitorio';
  end if;

  if not exists(
    select 1
    from pg_indexes
    where schemaname='public'
      and tablename='jl_aviator_rounds'
      and indexname='jl_aviator_rounds_transitional_id_idx'
  ) then
    raise exception 'indice parcial transitorio ausente';
  end if;
end
$$;

rollback;

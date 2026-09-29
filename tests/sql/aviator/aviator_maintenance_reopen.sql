begin;

update public.jl_aviator_rounds
   set status='CANCELLED',
       settled_at=coalesce(settled_at,now())
 where status in ('OPEN','LOCKED','FLYING');

update public.jl_aviator_settings
   set enabled=false,
       updated_at=now()
 where id=true;

do $$
declare
  v_cancelled_id bigint;
  v_tick jsonb;
  v_status text;
  v_new_id bigint;
begin
  insert into public.jl_aviator_rounds(status,betting_closes_at)
  values('OPEN',clock_timestamp()+interval '30 seconds')
  returning id into v_cancelled_id;

  v_tick:=public.jl_aviator_engine_tick();

  select status
    into v_status
  from public.jl_aviator_rounds
  where id=v_cancelled_id;

  if v_status<>'CANCELLED' then
    raise exception 'manutencao deve cancelar OPEN vazia; status=% tick=%',v_status,v_tick;
  end if;

  update public.jl_aviator_settings
     set enabled=true,
         updated_at=now()
   where id=true;

  v_tick:=public.jl_aviator_engine_tick();

  if coalesce((v_tick->>'opened')::boolean,false) is distinct from true then
    raise exception 'reabrir apos CANCELLED deve criar nova rodada: %',v_tick;
  end if;

  v_new_id:=(v_tick->>'round_id')::bigint;

  if v_new_id is null or v_new_id=v_cancelled_id then
    raise exception 'nova rodada invalida apos manutencao: %',v_tick;
  end if;

  select status
    into v_status
  from public.jl_aviator_rounds
  where id=v_new_id;

  if v_status<>'OPEN' then
    raise exception 'nova rodada deve estar OPEN; status=%',v_status;
  end if;
end
$$;

rollback;

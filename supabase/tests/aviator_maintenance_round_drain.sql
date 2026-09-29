begin;

-- Isola o teste de qualquer rodada viva criada por migrations anteriores.
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
  v_round_id bigint;
  v_tick jsonb;
  v_status text;
begin
  insert into public.jl_aviator_rounds(status,betting_closes_at)
  values('OPEN',clock_timestamp()-interval '1 second')
  returning id into v_round_id;

  v_tick:=public.jl_aviator_engine_tick();

  select status
    into v_status
    from public.jl_aviator_rounds
   where id=v_round_id;

  if v_status<>'CANCELLED' then
    raise exception 'OPEN vazia deve ser cancelada em manutencao, status=%',v_status;
  end if;

  if v_tick->>'action'<>'CANCELLED_EMPTY_OPEN' then
    raise exception 'engine deve informar cancelamento da OPEN vazia: %',v_tick;
  end if;

  if exists(
    select 1
      from public.jl_aviator_rounds
     where status in ('OPEN','LOCKED','FLYING')
  ) then
    raise exception 'manutencao nao pode deixar rodada vazia viva';
  end if;
end
$$;

rollback;

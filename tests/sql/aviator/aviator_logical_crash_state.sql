begin;

update public.jl_aviator_rounds
   set status='CANCELLED',
       settled_at=coalesce(settled_at,now())
 where status in ('OPEN','LOCKED','FLYING');

do $$
declare
  v_round_id bigint;
  v_state jsonb;
  v_row_status text;
  v_public_round jsonb;
begin
  insert into public.jl_aviator_rounds(
    status,
    opened_at,
    locked_at,
    started_at,
    betting_closes_at,
    effective_target,
    financial_ceiling,
    visual_target
  )
  values(
    'FLYING',
    clock_timestamp()-interval '30 seconds',
    clock_timestamp()-interval '25 seconds',
    clock_timestamp()-interval '20 seconds',
    clock_timestamp()-interval '21 seconds',
    1.01,
    1.01,
    20
  )
  returning id into v_round_id;

  v_state:=public.jl_aviator_public_state();
  v_public_round:=v_state->'round';

  if (v_public_round->>'id')::bigint<>v_round_id then
    raise exception 'public_state devolveu rodada inesperada';
  end if;

  if v_public_round->>'status'<>'CRASHED' then
    raise exception 'estado logico deveria estar CRASHED: %',v_public_round;
  end if;

  if (v_public_round->>'crash_multiplier')::numeric<>1.01 then
    raise exception 'multiplicador publico do crash incorreto: %',v_public_round;
  end if;

  if v_public_round ? 'financial_ceiling'
     or v_public_round ? 'effective_target'
     or v_public_round ? 'visual_target'
     or v_public_round ? 'total_staked' then
    raise exception 'estado publico expoe alvo/teto financeiro';
  end if;

  select status into v_row_status
  from public.jl_aviator_rounds
  where id=v_round_id;

  if v_row_status<>'FLYING' then
    raise exception 'public_state nao deve escrever/liquidar a rodada';
  end if;
end
$$;

rollback;

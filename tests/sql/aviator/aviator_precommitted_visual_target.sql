begin;

update public.jl_aviator_rounds
   set status='CANCELLED',
       settled_at=coalesce(settled_at,now())
 where status in ('OPEN','LOCKED','FLYING');

do $$
declare
  v_round_id bigint;
  v_result numeric;
  v_visual numeric;
  v_effective numeric;
  v_def text;
begin
  select pg_get_functiondef('public.jl_aviator_lock_round(bigint)'::regprocedure)
    into v_def;

  if position('visual_target=' in replace(lower(v_def),' ',''))=0
     or position('jl_aviator_fairness_visual_target' in lower(v_def))=0 then
    raise exception 'lock_round deve derivar e gravar o alvo visual precomprometido';
  end if;

  insert into public.jl_aviator_rounds(
    status,
    started_at,
    visual_target,
    effective_target,
    visual_extension
  )
  values(
    'FLYING',
    clock_timestamp(),
    20,
    2,
    false
  )
  returning id into v_round_id;

  v_result:=public.jl_aviator_set_visual_target(v_round_id,10);

  select visual_target,effective_target
    into v_visual,v_effective
  from public.jl_aviator_rounds
  where id=v_round_id;

  if v_visual<>20 or v_effective<>20 or v_result<>20 then
    raise exception 'alvo precomprometido deve permanecer 20; visual %, effective %, result %',
      v_visual,v_effective,v_result;
  end if;

  update public.jl_aviator_rounds
     set visual_extension=false,
         effective_target=2
   where id=v_round_id;

  v_result:=public.jl_aviator_set_visual_target(v_round_id,25);

  select visual_target,effective_target
    into v_visual,v_effective
  from public.jl_aviator_rounds
  where id=v_round_id;

  if v_visual<>20 or v_effective<>25 or v_result<>25 then
    raise exception 'multiplicador ja alcancado deve ser o piso sem alterar o alvo comprometido';
  end if;
end
$$;

rollback;

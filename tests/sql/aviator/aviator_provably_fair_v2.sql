begin;

do $$
declare
  v_open jsonb;
  v_round_id bigint;
  v_pre_commit text;
  v_after_commit text;
  v_lock_commit text;
  v_visual numeric;
  v_proof jsonb;
  v_seed text;
begin
  update public.jl_aviator_settings
     set enabled=true,
         one_round_test=false
   where id=true;

  update public.jl_aviator_rounds
     set status='CANCELLED',
         settled_at=coalesce(settled_at,now())
   where status in ('OPEN','LOCKED','FLYING','CRASHED');

  v_open:=public.jl_aviator_open_next_if_due();
  v_round_id:=(v_open->>'round_id')::bigint;

  if v_round_id is null then
    raise exception 'open_next nao criou rodada para teste';
  end if;

  select round_seed_commit,lock_proof_commit
    into v_pre_commit,v_lock_commit
  from public.jl_aviator_rounds
  where id=v_round_id;

  if v_pre_commit is null or length(v_pre_commit)<>64 then
    raise exception 'seed commit nao foi publicado na abertura';
  end if;

  if v_lock_commit is not null then
    raise exception 'lock commit nao deve existir antes do fecho';
  end if;

  perform public.jl_aviator_lock_round(v_round_id);

  select round_seed_commit,lock_proof_commit,visual_target
    into v_after_commit,v_lock_commit,v_visual
  from public.jl_aviator_rounds
  where id=v_round_id;

  if v_after_commit is distinct from v_pre_commit then
    raise exception 'seed commit mudou depois das apostas';
  end if;

  if v_lock_commit is null or length(v_lock_commit)<>64 then
    raise exception 'lock proof commit ausente';
  end if;

  update public.jl_aviator_rounds
     set status='CRASHED',
         crash_multiplier=v_visual,
         crashed_at=clock_timestamp()
   where id=v_round_id;

  perform public.jl_aviator_publish_proof(v_round_id);

  select round_seed_reveal
    into v_seed
  from public.jl_aviator_rounds
  where id=v_round_id;

  if v_seed is null or length(v_seed)<>64 then
    raise exception 'seed nao foi revelada depois do crash';
  end if;

  v_proof:=public.jl_aviator_round_proof(v_round_id);

  if coalesce((v_proof->>'proof_valid')::boolean,false) is not true then
    raise exception 'prova valida foi rejeitada: %',v_proof;
  end if;

  -- Alterar o resultado depois do compromisso precisa invalidar a prova.
  update public.jl_aviator_rounds
     set crash_multiplier=round(v_visual+0.125,6)
   where id=v_round_id;

  v_proof:=public.jl_aviator_round_proof(v_round_id);

  if coalesce((v_proof->>'proof_valid')::boolean,false) is true then
    raise exception 'resultado adulterado continuou valido';
  end if;

  if coalesce((v_proof->'checks'->>'result_valid')::boolean,true) is not false then
    raise exception 'result_valid nao detectou adulteracao';
  end if;

  -- A seed privada nao pode ser substituida.
  begin
    update public.jl_aviator_round_secrets
       set seed=case when seed=repeat('f',64) then repeat('e',64) else repeat('f',64) end
     where round_id=v_round_id;

    raise exception 'trigger permitiu alterar seed';
  exception
    when others then
      if sqlerrm='trigger permitiu alterar seed' then
        raise;
      end if;
      if position('Seed de rodada Aviator e imutavel' in sqlerrm)=0 then
        raise;
      end if;
  end;
end
$$;

rollback;

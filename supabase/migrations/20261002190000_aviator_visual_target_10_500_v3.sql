-- Aviator: novo intervalo do alvo visual para novas rodadas.
-- v2 permanece imutavel para preservar as provas historicas: 5x..135,7x.
-- v3 passa a usar 10x..500x.
-- Rodadas ja abertas/preparadas em v2 continuam v2 ate terminar.

create or replace function public.jl_aviator_fairness_visual_target_v3(
  p_seed_commit text
)
returns numeric
language plpgsql
immutable
strict
set search_path=pg_catalog,public
as $$
declare
  v_u numeric;
begin
  if p_seed_commit !~ '^[0-9a-f]{64}$' then
    raise exception 'Commit de seed invalido';
  end if;

  v_u:=('x'||substr(p_seed_commit,1,13))::bit(52)::bigint::numeric
       / 4503599627370495::numeric;

  return round(10::numeric + 490::numeric*v_u,6);
end
$$;

revoke all on function public.jl_aviator_fairness_visual_target_v3(text)
from public,anon,authenticated;
grant execute on function public.jl_aviator_fairness_visual_target_v3(text)
to service_role;

create or replace function public.jl_aviator_fairness_lock_payload_v3(
  p_round_id bigint,
  p_seed_commit text,
  p_total_staked numeric,
  p_financial_ceiling numeric,
  p_visual_target numeric,
  p_locked_effective_target numeric
)
returns text
language sql
immutable
strict
set search_path=pg_catalog,public
as $$
  select concat_ws(
    '|',
    'JL-AVIATOR-PF-v3',
    p_round_id::text,
    p_seed_commit,
    to_char(p_total_staked,'FM999999999999990.00'),
    coalesce(to_char(p_financial_ceiling,'FM999999999999990.000000'),'NULL'),
    to_char(p_visual_target,'FM999999999999990.000000'),
    to_char(p_locked_effective_target,'FM999999999999990.000000')
  );
$$;

revoke all on function public.jl_aviator_fairness_lock_payload_v3(
  bigint,text,numeric,numeric,numeric,numeric
) from public,anon,authenticated;
grant execute on function public.jl_aviator_fairness_lock_payload_v3(
  bigint,text,numeric,numeric,numeric,numeric
) to service_role;

create or replace function public.jl_aviator_prepare_fairness(
  p_round_id bigint
)
returns text
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  v_round public.jl_aviator_rounds;
  v_seed text;
  v_commit text;
  v_u numeric;
  v_target numeric;
  v_version text;
begin
  select *
    into v_round
  from public.jl_aviator_rounds
  where id=p_round_id
  for update;

  if not found then
    raise exception 'Rodada nao encontrada';
  end if;

  if v_round.status<>'OPEN' then
    raise exception 'Fairness so pode ser preparado em rodada OPEN';
  end if;

  -- Nao muda a regra de uma rodada que ja foi comprometida/publicada.
  v_version:=case
    when v_round.fairness_version in ('JL-AVIATOR-PF-v2','JL-AVIATOR-PF-v3')
      then v_round.fairness_version
    when v_round.round_seed_commit is not null
      then 'JL-AVIATOR-PF-v2'
    else 'JL-AVIATOR-PF-v3'
  end;

  select seed
    into v_seed
  from public.jl_aviator_round_secrets
  where round_id=p_round_id;

  if v_seed is null then
    v_seed:=encode(extensions.gen_random_bytes(32),'hex');
    v_commit:=encode(extensions.digest(v_seed,'sha256'),'hex');
    v_u:=('x'||substr(v_commit,1,13))::bit(52)::bigint::numeric
         / 4503599627370495::numeric;

    insert into public.jl_aviator_round_secrets(round_id,seed,unit_value)
    values(p_round_id,v_seed,v_u)
    on conflict(round_id) do nothing;

    select seed
      into v_seed
    from public.jl_aviator_round_secrets
    where round_id=p_round_id;
  end if;

  v_commit:=encode(extensions.digest(v_seed,'sha256'),'hex');

  v_target:=case
    when v_version='JL-AVIATOR-PF-v3'
      then public.jl_aviator_fairness_visual_target_v3(v_commit)
    else public.jl_aviator_fairness_visual_target(v_commit)
  end;

  if v_round.round_seed_commit is not null
     and v_round.round_seed_commit<>v_commit then
    raise exception 'Commit de fairness inconsistente';
  end if;

  update public.jl_aviator_rounds
     set fairness_version=v_version,
         round_seed_commit=v_commit,
         visual_seed_commit=v_commit,
         visual_target=v_target,
         round_seed_reveal=null,
         visual_seed_reveal=null
   where id=p_round_id;

  return v_commit;
end
$$;

revoke all on function public.jl_aviator_prepare_fairness(bigint)
from public,anon,authenticated;
grant execute on function public.jl_aviator_prepare_fairness(bigint)
to service_role;

create or replace function public.jl_aviator_lock_round(p_round_id bigint)
returns public.jl_aviator_rounds
language plpgsql
security definer
set search_path to 'pg_catalog','public','extensions'
as $$
declare
  v_round public.jl_aviator_rounds;
  v_bank public.jl_aviator_bank;
  v_total numeric;
  v_seed text;
  v_commit text;
  v_visual numeric;
  v_financial numeric;
  v_locked_effective numeric;
  v_payload text;
  v_lock_commit text;
  v_exposure_ratio numeric;
  v_version text;
begin
  select *
    into v_round
  from public.jl_aviator_rounds
  where id=p_round_id
  for update;

  if not found or v_round.status<>'OPEN' then
    raise exception 'Rodada nao esta OPEN';
  end if;

  if v_round.round_seed_commit is null
     or not exists(
       select 1 from public.jl_aviator_round_secrets
       where round_id=p_round_id
     ) then
    perform public.jl_aviator_prepare_fairness(p_round_id);

    select *
      into v_round
    from public.jl_aviator_rounds
    where id=p_round_id;
  end if;

  v_version:=case
    when v_round.fairness_version in ('JL-AVIATOR-PF-v2','JL-AVIATOR-PF-v3')
      then v_round.fairness_version
    else 'JL-AVIATOR-PF-v2'
  end;

  select seed
    into v_seed
  from public.jl_aviator_round_secrets
  where round_id=p_round_id;

  v_commit:=encode(extensions.digest(v_seed,'sha256'),'hex');

  if v_round.round_seed_commit<>v_commit then
    raise exception 'Seed nao corresponde ao compromisso pre-aposta';
  end if;

  v_visual:=case
    when v_version='JL-AVIATOR-PF-v3'
      then public.jl_aviator_fairness_visual_target_v3(v_commit)
    else public.jl_aviator_fairness_visual_target(v_commit)
  end;

  select *
    into v_bank
  from public.jl_aviator_bank
  where id=true
  for update;

  v_exposure_ratio:=public.jl_aviator_exposure_ratio_at(clock_timestamp());

  select coalesce(sum(stake),0)
    into v_total
  from public.jl_aviator_bets
  where round_id=p_round_id
    and status='ACTIVE';

  v_financial:=public.jl_aviator_financial_ceiling(
    v_bank.balance,
    v_total,
    v_exposure_ratio
  );

  v_locked_effective:=case
    when v_total=0 then v_visual
    else v_financial
  end;

  v_payload:=case
    when v_version='JL-AVIATOR-PF-v3' then
      public.jl_aviator_fairness_lock_payload_v3(
        p_round_id,
        v_commit,
        v_total,
        v_financial,
        v_visual,
        v_locked_effective
      )
    else
      public.jl_aviator_fairness_lock_payload(
        p_round_id,
        v_commit,
        v_total,
        v_financial,
        v_visual,
        v_locked_effective
      )
  end;

  v_lock_commit:=encode(extensions.digest(v_payload,'sha256'),'hex');

  update public.jl_aviator_rounds
     set status='LOCKED',
         engine_due_at=coalesce(v_round.takeoff_at,clock_timestamp()+interval '3 seconds'),
         locked_at=clock_timestamp(),
         bank_balance_snapshot=v_bank.balance,
         exposure_ratio_snapshot=v_exposure_ratio,
         risk_reserve=round(v_bank.balance*v_exposure_ratio,2),
         total_staked=v_total,
         financial_ceiling=v_financial,
         visual_target=v_visual,
         round_seed_commit=v_commit,
         visual_seed_commit=v_commit,
         lock_proof_commit=v_lock_commit,
         locked_effective_target=v_locked_effective,
         effective_target=v_locked_effective,
         round_seed_reveal=null,
         visual_seed_reveal=null,
         visual_extension=(v_total=0),
         fairness_version=v_version
   where id=p_round_id
  returning * into v_round;

  perform public.jl_aviator_schedule_next_engine_event(p_round_id);

  select *
    into v_round
  from public.jl_aviator_rounds
  where id=p_round_id;

  return v_round;
end;
$$;

revoke all on function public.jl_aviator_lock_round(bigint)
from public,anon,authenticated;
grant execute on function public.jl_aviator_lock_round(bigint)
to service_role;

create or replace function public.jl_aviator_round_proof(p_round_id bigint)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  r public.jl_aviator_rounds;
  v_seed text;
  v_seed_commit text;
  v_visual numeric;
  v_payload text;
  v_lock_commit text;
  v_financial numeric;
  v_expected_final numeric;
  v_seed_ok boolean:=false;
  v_visual_ok boolean:=false;
  v_lock_ok boolean:=false;
  v_financial_ok boolean:=false;
  v_result_ok boolean:=false;
begin
  select *
    into r
  from public.jl_aviator_rounds
  where id=p_round_id;

  if not found then
    raise exception 'Rodada nao encontrada';
  end if;

  if r.status not in ('CRASHED','SETTLED') then
    return jsonb_build_object(
      'available',false,
      'round_id',r.id,
      'round_no',r.round_no,
      'status',r.status,
      'reason','proof_available_after_crash'
    );
  end if;

  if r.fairness_version not in ('JL-AVIATOR-PF-v2','JL-AVIATOR-PF-v3') then
    return jsonb_build_object(
      'available',false,
      'round_id',r.id,
      'round_no',r.round_no,
      'status',r.status,
      'reason','legacy_round'
    );
  end if;

  v_seed:=coalesce(r.round_seed_reveal,r.visual_seed_reveal);

  if v_seed is not null then
    v_seed_commit:=encode(extensions.digest(v_seed,'sha256'),'hex');
    v_seed_ok:=v_seed_commit=r.round_seed_commit;
  end if;

  if r.round_seed_commit is not null then
    v_visual:=case
      when r.fairness_version='JL-AVIATOR-PF-v3'
        then public.jl_aviator_fairness_visual_target_v3(r.round_seed_commit)
      else public.jl_aviator_fairness_visual_target(r.round_seed_commit)
    end;
    v_visual_ok:=round(v_visual,6)=round(r.visual_target,6);
  end if;

  v_payload:=case
    when r.fairness_version='JL-AVIATOR-PF-v3' then
      public.jl_aviator_fairness_lock_payload_v3(
        r.id,
        r.round_seed_commit,
        r.total_staked,
        r.financial_ceiling,
        r.visual_target,
        r.locked_effective_target
      )
    else
      public.jl_aviator_fairness_lock_payload(
        r.id,
        r.round_seed_commit,
        r.total_staked,
        r.financial_ceiling,
        r.visual_target,
        r.locked_effective_target
      )
  end;

  v_lock_commit:=encode(extensions.digest(v_payload,'sha256'),'hex');
  v_lock_ok:=v_lock_commit=r.lock_proof_commit;

  v_financial:=public.jl_aviator_financial_ceiling(
    r.bank_balance_snapshot,
    r.total_staked,
    r.exposure_ratio_snapshot
  );

  v_financial_ok:=case
    when r.total_staked=0 then r.financial_ceiling is null
    else round(v_financial,6)=round(r.financial_ceiling,6)
  end;

  v_expected_final:=case
    when r.visual_extension then
      greatest(
        r.visual_target,
        coalesce(r.zero_exposure_at_multiplier,r.visual_target)
      )
    else
      r.locked_effective_target
  end;

  v_result_ok:=
    v_expected_final is not null
    and r.crash_multiplier is not null
    and round(v_expected_final,6)=round(r.crash_multiplier,6);

  return jsonb_build_object(
    'available',true,
    'round_id',r.id,
    'round_no',r.round_no,
    'status',r.status,
    'fairness_version',r.fairness_version,
    'seed_commit',r.round_seed_commit,
    'seed',v_seed,
    'lock_commit',r.lock_proof_commit,
    'lock_payload',v_payload,
    'inputs',jsonb_build_object(
      'total_staked',r.total_staked,
      'visual_target',r.visual_target,
      'visual_extension',r.visual_extension,
      'financial_ceiling',r.financial_ceiling,
      'locked_effective_target',r.locked_effective_target,
      'zero_exposure_at_multiplier',r.zero_exposure_at_multiplier
    ),
    'result',jsonb_build_object(
      'actual_crash_multiplier',r.crash_multiplier,
      'expected_crash_multiplier',v_expected_final
    ),
    'checks',jsonb_build_object(
      'result_valid',v_result_ok,
      'lock_commit_valid',v_lock_ok,
      'seed_commit_valid',v_seed_ok,
      'visual_target_valid',v_visual_ok,
      'financial_ceiling_valid',v_financial_ok
    ),
    'proof_valid',
      v_seed_ok
      and v_visual_ok
      and v_lock_ok
      and v_financial_ok
      and v_result_ok,
    'published_at',r.proof_published_at
  );
end
$$;

revoke all on function public.jl_aviator_round_proof(bigint) from public;
grant execute on function public.jl_aviator_round_proof(bigint)
to anon,authenticated,service_role;

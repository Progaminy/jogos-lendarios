-- Aviator: restaurar alvo visual precomprometido antes do voo.
-- A seed e o visual_target sao definidos no LOCK.
-- Com apostas ativas, o effective_target continua a ser o teto financeiro.
-- Quando a exposicao chega a zero, effective_target passa a
-- greatest(visual_target precomprometido, multiplicador ja alcancado).

create or replace function public.jl_aviator_lock_round(p_round_id bigint)
returns public.jl_aviator_rounds
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  v_round public.jl_aviator_rounds;
  v_bank public.jl_aviator_bank;
  v_total numeric;
  v_seed text;
  v_commit text;
  v_u numeric;
  v_target numeric;
  v_financial numeric;
begin
  select * into v_round
  from public.jl_aviator_rounds
  where id=p_round_id
  for update;

  if not found or v_round.status<>'OPEN' then
    raise exception 'Rodada nao esta OPEN';
  end if;

  select * into v_bank
  from public.jl_aviator_bank
  where id=true
  for update;

  select coalesce(sum(stake),0)
    into v_total
  from public.jl_aviator_bets
  where round_id=p_round_id
    and status='ACTIVE';

  v_seed:=encode(extensions.gen_random_bytes(32),'hex');
  v_commit:=encode(extensions.digest(v_seed,'sha256'),'hex');
  v_u:=('x'||substr(v_commit,1,8))::bit(32)::bigint/4294967295.0;
  v_target:=round(5+130.7*v_u,6);
  v_financial:=public.jl_aviator_financial_ceiling(
    v_bank.balance,
    v_total,
    v_bank.exposure_ratio
  );

  insert into public.jl_aviator_round_secrets(round_id,seed,unit_value)
  values(p_round_id,v_seed,v_u)
  on conflict(round_id) do update
    set seed=excluded.seed,
        unit_value=excluded.unit_value;

  update public.jl_aviator_rounds
  set status='LOCKED',
      locked_at=now(),
      bank_balance_snapshot=v_bank.balance,
      risk_reserve=round(v_bank.balance*v_bank.exposure_ratio,2),
      total_staked=v_total,
      financial_ceiling=v_financial,
      visual_target=v_target,
      visual_seed_commit=v_commit,
      visual_seed_reveal=null,
      effective_target=case
        when v_total=0 then v_target
        else v_financial
      end,
      visual_extension=(v_total=0)
  where id=p_round_id
  returning * into v_round;

  return v_round;
end
$$;

create or replace function public.jl_aviator_set_visual_target(
  p_round_id bigint,
  p_current numeric
)
returns numeric
language plpgsql
security definer
set search_path=public
as $$
declare
  v_precommitted numeric;
  v_effective numeric;
begin
  select visual_target
    into v_precommitted
  from public.jl_aviator_rounds
  where id=p_round_id
  for update;

  if not found then
    raise exception 'Rodada nao encontrada';
  end if;

  -- Compatibilidade apenas para rodadas antigas criadas antes desta migration.
  if v_precommitted is null then
    v_precommitted:=public.jl_aviator_extension_target(p_round_id,p_current);

    update public.jl_aviator_rounds
       set visual_target=v_precommitted
     where id=p_round_id;
  end if;

  v_effective:=greatest(p_current,v_precommitted);

  update public.jl_aviator_rounds
     set visual_extension=true,
         zero_exposure_at_multiplier=p_current,
         effective_target=v_effective
   where id=p_round_id
     and status='FLYING';

  return v_effective;
end
$$;

revoke all on function public.jl_aviator_lock_round(bigint) from public,anon,authenticated;
grant execute on function public.jl_aviator_lock_round(bigint) to service_role;

revoke all on function public.jl_aviator_set_visual_target(bigint,numeric) from public,anon,authenticated;
grant execute on function public.jl_aviator_set_visual_target(bigint,numeric) to service_role;

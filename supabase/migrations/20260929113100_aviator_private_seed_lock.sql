-- Aviator: o alvo visual e precomprometido, mas a seed fica privada ate ao fim.
create or replace function public.jl_aviator_lock_round(p_round_id bigint)
returns public.jl_aviator_rounds
language plpgsql security definer
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
begin
  select * into v_round from public.jl_aviator_rounds where id=p_round_id for update;
  if not found or v_round.status<>'OPEN' then raise exception 'Rodada nao esta OPEN'; end if;
  select * into v_bank from public.jl_aviator_bank where id=true for update;
  select coalesce(sum(stake),0) into v_total from public.jl_aviator_bets where round_id=p_round_id and status='ACTIVE';

  v_seed:=encode(extensions.gen_random_bytes(32),'hex');
  v_commit:=encode(extensions.digest(v_seed,'sha256'),'hex');
  v_u:=('x'||substr(v_commit,1,8))::bit(32)::bigint/4294967295.0;
  v_target:=round(5+130.7*v_u,6);

  insert into public.jl_aviator_round_secrets(round_id,seed,unit_value)
  values(p_round_id,v_seed,v_u);

  update public.jl_aviator_rounds
  set status='LOCKED',locked_at=now(),bank_balance_snapshot=v_bank.balance,
      risk_reserve=round(v_bank.balance*v_bank.exposure_ratio,2),total_staked=v_total,
      financial_ceiling=public.jl_aviator_financial_ceiling(v_bank.balance,v_total,v_bank.exposure_ratio),
      visual_target=case when v_total=0 then v_target else null end,
      visual_seed_commit=v_commit,visual_seed_reveal=null,
      effective_target=case when v_total=0 then v_target else public.jl_aviator_financial_ceiling(v_bank.balance,v_total,v_bank.exposure_ratio) end,
      visual_extension=(v_total=0)
  where id=p_round_id returning * into v_round;
  return v_round;
end $$;

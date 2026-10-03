-- Aviator: ajuste da banca com jogo aberto + reabertura administrativa sem veto.
-- Regras:
-- 1. O administrador pode aumentar ou reduzir a parte LIVRE da banca sem fechar o Aviator.
-- 2. Uma redução nunca pode consumir a reserva necessária às apostas ACTIVE.
-- 3. Reabrir é uma decisão administrativa explícita: certificação e drenagem são informativas,
--    não podem negar a reabertura.
-- 4. Reinstala jl_aviator_admin_state para eliminar drift/erro de record "r".round_id.

create or replace function public.jl_aviator_admin_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $function$
declare
  b public.jl_aviator_bank;
  r public.jl_aviator_rounds;
  s public.jl_aviator_settings;
  v_bets int:=0;
  v_players int:=0;
  v_staked numeric:=0;
  v_paid numeric:=0;
  v_active_stake numeric:=0;
  v_active_bets int:=0;
  v_cashouts int:=0;
  v_cashout_stake numeric:=0;
  v_refunded int:=0;
  v_refunded_stake numeric:=0;
  v_lost int:=0;
  v_lost_stake numeric:=0;
  v_limit numeric:=1;
  v_projected_ceiling numeric:=1;
  v_potential_payment numeric:=0;
  v_bank_balance numeric:=0;
  v_exposure_ratio numeric:=0.5;
  v_risk_budget numeric:=0;
  v_active_liability numeric:=0;
  v_available_after_worst numeric:=0;
  v_risk_usage_pct numeric:=0;
  v_cashout_profit_paid numeric:=0;
  v_round_house_result numeric:=0;
  v_house_status text:='HEALTHY';
begin
  perform public.jl_require_admin(p_token);

  select * into b
  from public.jl_aviator_bank
  where id=true;

  select * into s
  from public.jl_aviator_settings
  where id=true;

  select * into r
  from public.jl_aviator_rounds
  order by id desc
  limit 1;

  v_bank_balance:=coalesce(b.balance,0);
  v_exposure_ratio:=coalesce(b.exposure_ratio,0.5);
  v_risk_budget:=round(greatest(v_bank_balance*v_exposure_ratio,0),2);

  if r.id is not null then
    select
      count(*),
      count(distinct player_id),
      coalesce(sum(stake),0),
      coalesce(sum(payout) filter(where status='CASHED_OUT'),0),
      coalesce(sum(stake) filter(where status='ACTIVE'),0),
      count(*) filter(where status='ACTIVE'),
      count(*) filter(where status='CASHED_OUT'),
      coalesce(sum(stake) filter(where status='CASHED_OUT'),0),
      count(*) filter(where status='REFUNDED'),
      coalesce(sum(stake) filter(where status='REFUNDED'),0),
      count(*) filter(where status='LOST'),
      coalesce(sum(stake) filter(where status='LOST'),0)
    into
      v_bets,
      v_players,
      v_staked,
      v_paid,
      v_active_stake,
      v_active_bets,
      v_cashouts,
      v_cashout_stake,
      v_refunded,
      v_refunded_stake,
      v_lost,
      v_lost_stake
    from public.jl_aviator_bets
    where round_id=r.id;

    if v_active_stake>0 then
      if r.status='OPEN' then
        v_projected_ceiling:=
          case
            when v_staked>0
              then 1+(v_bank_balance*v_exposure_ratio/v_staked)
            else 1
          end;

        v_limit:=coalesce(
          r.locked_effective_target,
          r.effective_target,
          r.visual_target,
          r.financial_ceiling,
          v_projected_ceiling,
          1
        );
      else
        v_limit:=coalesce(
          r.locked_effective_target,
          r.effective_target,
          r.visual_target,
          r.financial_ceiling,
          1
        );
      end if;

      v_limit:=greatest(v_limit,1);
    end if;

    v_potential_payment:=round(v_paid+(v_active_stake*v_limit),2);
  end if;

  v_active_liability:=round(
    greatest(v_active_stake*(v_limit-1),0),
    2
  );

  v_available_after_worst:=round(v_bank_balance-v_active_liability,2);

  v_risk_usage_pct:=
    case
      when v_risk_budget>0 then
        round(least(greatest(v_active_liability/v_risk_budget*100,0),9999),2)
      when v_active_liability>0 then 9999
      else 0
    end;

  v_cashout_profit_paid:=round(greatest(v_paid-v_cashout_stake,0),2);
  v_round_house_result:=round(v_lost_stake-v_cashout_profit_paid,2);

  v_house_status:=
    case
      when v_bank_balance<=0
        or v_available_after_worst<0
        or v_risk_usage_pct>=90 then 'CRITICAL'
      when v_risk_usage_pct>=70 then 'ATTENTION'
      else 'HEALTHY'
    end;

  return jsonb_build_object(
    'enabled',coalesce(s.enabled,true),
    'one_round_test',coalesce(s.one_round_test,false),
    'maintenance_message',coalesce(s.maintenance_message,'Aviator brevemente.'),
    'bank',jsonb_build_object(
      'balance',v_bank_balance,
      'exposure_ratio',v_exposure_ratio
    ),
    'round',case when r.id is null then null else jsonb_build_object(
      'id',r.id,
      'round_no',r.round_no,
      'status',r.status,
      'total_staked',r.total_staked,
      'risk_reserve',r.risk_reserve,
      'financial_ceiling',r.financial_ceiling,
      'crash_multiplier',r.crash_multiplier,
      'visual_extension',r.visual_extension,
      'opened_at',r.opened_at,
      'started_at',r.started_at
    ) end,
    'exposure',jsonb_build_object(
      'total_staked',v_staked,
      'potential_payment',v_potential_payment,
      'players',v_players,
      'cashouts',v_cashouts,
      'cashout_paid',v_paid,
      'active_bets',v_active_bets,
      'active_stake',v_active_stake,
      'refunded_bets',v_refunded,
      'refunded_stake',v_refunded_stake,
      'lost_bets',v_lost,
      'lost_stake',v_lost_stake,
      'limit_multiplier',v_limit
    ),
    'house',jsonb_build_object(
      'status',v_house_status,
      'bank_balance',v_bank_balance,
      'risk_budget',v_risk_budget,
      'active_liability',v_active_liability,
      'available_after_worst_case',v_available_after_worst,
      'risk_usage_pct',v_risk_usage_pct,
      'cashout_profit_paid',v_cashout_profit_paid,
      'round_realized_result',v_round_house_result,
      'updated_at',clock_timestamp()
    ),
    'bets',v_bets,
    'stake_sum',v_staked,
    'paid_sum',v_paid
  );
end;
$function$;

revoke all on function public.jl_aviator_admin_state(text) from public;
grant execute on function public.jl_aviator_admin_state(text)
to anon,authenticated,service_role;


create or replace function public.jl_aviator_admin_adjust_bank(
  p_token text,
  p_delta numeric,
  p_reason text,
  p_request_key text
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $function$
declare
  v_bank public.jl_aviator_bank;
  v_existing public.jl_aviator_bank_ledger;
  v_admin uuid:=public.jl_admin_account_id(p_token);
  v_reason text:=left(trim(coalesce(p_reason,'')),160);
  v_before jsonb;
  v_after jsonb;
  v_active_liability numeric:=0;
  v_live_exposure_ratio numeric:=0.5;
  v_minimum_balance numeric:=0;
  v_new_balance numeric;
begin
  if v_admin is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  if p_request_key is null
     or length(trim(p_request_key))<8
     or length(p_request_key)>100 then
    raise exception 'Chave do ajuste invalida';
  end if;

  if p_delta is null
     or p_delta=0
     or abs(p_delta)>100000000
     or round(p_delta,2)<>p_delta then
    raise exception 'Ajuste invalido';
  end if;

  if length(v_reason)<3 then
    raise exception 'Informe o motivo';
  end if;

  -- Serializa apenas retries do MESMO pedido. Não existe mais um cadeado global
  -- que obrigue todos os ajustes administrativos a esperar entre si.
  perform pg_advisory_xact_lock(
    hashtext('jl_aviator_bank_adjust:'||trim(p_request_key))
  );

  select * into v_existing
  from public.jl_aviator_bank_ledger
  where request_key=p_request_key;

  if v_existing.id is not null then
    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'balance',v_existing.balance_after
    );
  end if;

  select * into v_bank
  from public.jl_aviator_bank
  where id=true
  for update;

  if v_bank.id is null then
    raise exception 'Banca do Aviator não encontrada.';
  end if;

  v_new_balance:=round(v_bank.balance+p_delta,2);

  if v_new_balance<0 then
    raise exception 'Ajuste deixaria a banca negativa';
  end if;

  -- A banca pode ser alterada com o jogo aberto. Numa redução, protege-se
  -- somente a parte já comprometida com apostas ACTIVE.
  if p_delta<0 then
    select
      coalesce(sum(
        greatest(
          bet.stake*(
            greatest(
              coalesce(
                rnd.locked_effective_target,
                rnd.effective_target,
                rnd.visual_target,
                rnd.financial_ceiling,
                1
              ),
              1
            )-1
          ),
          0
        )
      ),0),
      coalesce(
        min(
          case
            when rnd.exposure_ratio_snapshot is not null
              then rnd.exposure_ratio_snapshot
            else v_bank.exposure_ratio
          end
        ),
        v_bank.exposure_ratio,
        0.5
      )
    into v_active_liability,v_live_exposure_ratio
    from public.jl_aviator_bets bet
    join public.jl_aviator_rounds rnd
      on rnd.id=bet.round_id
    where bet.status='ACTIVE'
      and rnd.status in ('OPEN','LOCKED','FLYING');

    v_active_liability:=round(greatest(coalesce(v_active_liability,0),0),2);
    v_live_exposure_ratio:=greatest(coalesce(v_live_exposure_ratio,0.5),0);

    if v_active_liability>0 then
      if v_live_exposure_ratio<=0 then
        raise exception 'A banca está totalmente reservada por apostas ativas.';
      end if;

      v_minimum_balance:=
        ceil((v_active_liability/v_live_exposure_ratio)*100)/100;

      if v_new_balance<v_minimum_balance then
        raise exception
          'Ajuste excede o valor livre da banca. Mínimo protegido durante apostas ativas: % MZN.',
          to_char(v_minimum_balance,'FM999999999990.00');
      end if;
    end if;
  end if;

  v_before:=jsonb_build_object(
    'balance',v_bank.balance,
    'exposure_ratio',v_bank.exposure_ratio
  );

  update public.jl_aviator_bank
     set balance=v_new_balance,
         updated_at=clock_timestamp()
   where id=true
  returning * into v_bank;

  insert into public.jl_aviator_bank_ledger(
    delta,balance_after,reason,request_key
  )
  values(
    round(p_delta,2),
    v_bank.balance,
    v_reason,
    p_request_key
  );

  v_after:=jsonb_build_object(
    'balance',v_bank.balance,
    'exposure_ratio',v_bank.exposure_ratio
  );

  insert into public.audit_log(
    action,
    details,
    actor_admin_id,
    actor_session_id,
    actor_name,
    actor_role,
    target_type,
    target_id,
    before_state,
    after_state
  )
  values(
    'aviator.admin.bank_adjusted',
    jsonb_build_object(
      'delta',round(p_delta,2),
      'reason',v_reason,
      'requestKey',p_request_key,
      'liveAdjustment',true,
      'activeLiability',v_active_liability,
      'minimumProtectedBalance',v_minimum_balance
    ),
    v_admin,
    nullif(current_setting('jl.admin_session_id',true),'')::uuid,
    nullif(current_setting('jl.admin_name',true),''),
    nullif(current_setting('jl.admin_role',true),''),
    'aviator_bank',
    'global',
    v_before,
    v_after
  );

  return jsonb_build_object(
    'ok',true,
    'already_processed',false,
    'balance',v_bank.balance,
    'live_adjustment',true,
    'active_liability',v_active_liability,
    'minimum_protected_balance',v_minimum_balance
  );
end;
$function$;

revoke all on function public.jl_aviator_admin_adjust_bank(text,numeric,text,text)
from public;
grant execute on function public.jl_aviator_admin_adjust_bank(text,numeric,text,text)
to anon,authenticated,service_role;


-- A certificação continua disponível como diagnóstico manual, porém não veta
-- a decisão explícita do administrador de abrir o Aviator.
create or replace function public.jl_aviator_admin_set_enabled(
  p_token text,
  p_enabled boolean
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $function$
declare
  v_result jsonb;
begin
  if p_enabled is null then
    raise exception 'Estado de manutenção inválido.';
  end if;

  v_result:=public.jl_aviator_admin_set_enabled_core(p_token,p_enabled);

  if p_enabled then
    return v_result||jsonb_build_object(
      'release_gate_enforced',false,
      'release_gate_is_informational',true
    );
  end if;

  return v_result;
end;
$function$;

revoke all on function public.jl_aviator_admin_set_enabled(text,boolean)
from public;
grant execute on function public.jl_aviator_admin_set_enabled(text,boolean)
to anon,authenticated,service_role;


create or replace function public.jl_aviator_admin_reopen(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $function$
declare
  v_state jsonb;
  v_result jsonb;
  v_round_status text;
begin
  perform public.jl_require_admin(p_token);

  v_state:=public.jl_aviator_admin_state(p_token);

  if coalesce((v_state->>'enabled')::boolean,false) then
    return jsonb_build_object(
      'ok',true,
      'enabled',true,
      'already_open',true,
      'maintenance_message','Aviator brevemente.'
    );
  end if;

  v_round_status:=v_state->'round'->>'status';

  -- Sem bloqueio por OPEN/LOCKED/FLYING/CRASHED e sem veto de certificação.
  -- A rodada em curso continua protegida pelo motor; habilitar só permite que
  -- o ciclo normal prossiga e que novas rodadas sejam abertas quando couber.
  v_result:=public.jl_aviator_admin_set_enabled(p_token,true);

  return v_result||jsonb_build_object(
    'ok',true,
    'enabled',true,
    'already_open',false,
    'ready_for_new_rounds',true,
    'round_in_progress',case
      when v_round_status in ('OPEN','LOCKED','FLYING','CRASHED')
        then v_round_status
      else null
    end
  );
end;
$function$;

revoke all on function public.jl_aviator_admin_reopen(text)
from public;
grant execute on function public.jl_aviator_admin_reopen(text)
to anon,authenticated,service_role;

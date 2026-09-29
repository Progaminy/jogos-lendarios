-- Aviator: indicador financeiro da casa, calculado no servidor.
-- O painel apenas apresenta o snapshot e atualiza periodicamente.

create or replace function public.jl_aviator_admin_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
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

        v_limit:=coalesce(r.financial_ceiling,v_projected_ceiling,1);

        if r.visual_target is not null then
          v_limit:=least(v_limit,r.visual_target);
        end if;
      else
        v_limit:=coalesce(
          r.locked_effective_target,
          r.effective_target,
          r.financial_ceiling,
          r.visual_target,
          1
        );
      end if;

      v_limit:=greatest(v_limit,1);
    else
      v_limit:=1;
    end if;

    v_potential_payment:=round(
      v_paid+(v_active_stake*v_limit),
      2
    );
  end if;

  -- A casa só arrisca o lucro potencial sobre apostas ainda ativas.
  -- O stake do próprio jogador não é custo económico da banca.
  v_active_liability:=round(
    greatest(v_active_stake*(v_limit-1),0),
    2
  );

  v_available_after_worst:=round(
    v_bank_balance-v_active_liability,
    2
  );

  v_risk_usage_pct:=
    case
      when v_risk_budget>0
        then round(
          least(greatest(v_active_liability/v_risk_budget*100,0),9999),
          2
        )
      when v_active_liability>0
        then 9999
      else 0
    end;

  v_cashout_profit_paid:=round(
    greatest(v_paid-v_cashout_stake,0),
    2
  );

  -- Resultado realizado da rodada para a banca:
  -- stakes perdidos menos lucro já pago em cash-out.
  v_round_house_result:=round(
    v_lost_stake-v_cashout_profit_paid,
    2
  );

  v_house_status:=
    case
      when v_bank_balance<=0
        or v_available_after_worst<0
        or v_risk_usage_pct>=90
        then 'CRITICAL'
      when v_risk_usage_pct>=70
        then 'ATTENTION'
      else 'HEALTHY'
    end;

  return jsonb_build_object(
    'enabled',coalesce(s.enabled,true),
    'one_round_test',coalesce(s.one_round_test,false),
    'maintenance_message',coalesce(
      s.maintenance_message,
      'Aviator brevemente.'
    ),
    'bank',jsonb_build_object(
      'balance',v_bank_balance,
      'exposure_ratio',v_exposure_ratio
    ),
    'round',case when r.id is null then null else jsonb_build_object(
      'id',r.id,
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
end
$$;

revoke all on function public.jl_aviator_admin_state(text)
from public;
grant execute on function public.jl_aviator_admin_state(text)
to anon,authenticated;

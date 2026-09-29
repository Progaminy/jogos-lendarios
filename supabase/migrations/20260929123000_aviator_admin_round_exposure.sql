-- Aviator: exposição financeira da rodada no painel administrativo.
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
  v_refunded int:=0;
  v_lost int:=0;
  v_limit numeric:=1;
  v_projected_ceiling numeric:=1;
  v_potential_payment numeric:=0;
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

  if r.id is not null then
    select
      count(*),
      count(distinct player_id),
      coalesce(sum(stake),0),
      coalesce(sum(payout) filter(where status='CASHED_OUT'),0),
      coalesce(sum(stake) filter(where status='ACTIVE'),0),
      count(*) filter(where status='ACTIVE'),
      count(*) filter(where status='CASHED_OUT'),
      count(*) filter(where status='REFUNDED'),
      count(*) filter(where status='LOST')
    into
      v_bets,
      v_players,
      v_staked,
      v_paid,
      v_active_stake,
      v_active_bets,
      v_cashouts,
      v_refunded,
      v_lost
    from public.jl_aviator_bets
    where round_id=r.id;

    if v_active_stake>0 then
      if r.status='OPEN' then
        v_projected_ceiling:=
          case
            when v_staked>0
              then 1+(
                coalesce(b.balance,0)*
                coalesce(b.exposure_ratio,0.5)/
                v_staked
              )
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

  return jsonb_build_object(
    'enabled',coalesce(s.enabled,true),
    'one_round_test',coalesce(s.one_round_test,false),
    'maintenance_message',coalesce(
      s.maintenance_message,
      'Aviator brevemente.'
    ),
    'bank',jsonb_build_object(
      'balance',coalesce(b.balance,0),
      'exposure_ratio',coalesce(b.exposure_ratio,0.5)
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
      'lost_bets',v_lost,
      'limit_multiplier',v_limit
    ),
    -- Compatibilidade com consumidores antigos.
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

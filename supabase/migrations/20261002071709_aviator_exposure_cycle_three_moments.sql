-- Aviator: ciclo de exposição financeira em 3 momentos de 3,5 horas.
-- Momento 1: 1/4 da banca; Momento 2: 1/3; Momento 3: 1/2.
-- O ciclo dura 10,5 horas e reinicia automaticamente.
-- A fração vigente é congelada no LOCK da rodada.

alter table public.jl_aviator_bank
  add column if not exists exposure_cycle_anchor timestamptz;

update public.jl_aviator_bank
   set exposure_cycle_anchor=coalesce(exposure_cycle_anchor,clock_timestamp()),
       exposure_ratio=.5,
       updated_at=clock_timestamp()
 where id=true;

alter table public.jl_aviator_bank
  alter column exposure_cycle_anchor set default clock_timestamp();

alter table public.jl_aviator_bank
  alter column exposure_cycle_anchor set not null;

comment on column public.jl_aviator_bank.exposure_cycle_anchor is
  'Inicio do ciclo repetitivo de 10,5h: 3,5h a 1/4, 3,5h a 1/3, 3,5h a 1/2.';

create or replace function public.jl_aviator_exposure_cycle_state(
  p_at timestamptz default clock_timestamp()
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_at timestamptz:=coalesce(p_at,clock_timestamp());
  v_anchor timestamptz;
  v_elapsed_seconds bigint;
  v_cycle_number bigint;
  v_cycle_offset bigint;
  v_moment integer;
  v_ratio numeric;
  v_cycle_started_at timestamptz;
  v_phase_started_at timestamptz;
  v_phase_ends_at timestamptz;
begin
  select exposure_cycle_anchor
    into v_anchor
  from public.jl_aviator_bank
  where id=true;

  if v_anchor is null then
    raise exception 'Ciclo financeiro do Aviator nao configurado';
  end if;

  v_elapsed_seconds:=greatest(
    0,
    floor(extract(epoch from (v_at-v_anchor)))::bigint
  );
  v_cycle_number:=v_elapsed_seconds/37800;
  v_cycle_offset:=v_elapsed_seconds%37800;

  v_moment:=case
    when v_cycle_offset<12600 then 1
    when v_cycle_offset<25200 then 2
    else 3
  end;

  v_ratio:=case v_moment
    when 1 then .25::numeric
    when 2 then round(1::numeric/3,6)
    else .5::numeric
  end;

  v_cycle_started_at:=v_anchor+
    make_interval(secs=>(v_cycle_number*37800)::double precision);
  v_phase_started_at:=v_cycle_started_at+
    make_interval(secs=>((v_moment-1)*12600)::double precision);
  v_phase_ends_at:=v_phase_started_at+interval '3 hours 30 minutes';

  return jsonb_build_object(
    'moment',v_moment,
    'fraction',
      case v_moment when 1 then '1/4' when 2 then '1/3' else '1/2' end,
    'exposure_ratio',v_ratio,
    'phase_seconds',12600,
    'cycle_seconds',37800,
    'cycle_started_at',v_cycle_started_at,
    'cycle_ends_at',v_cycle_started_at+interval '10 hours 30 minutes',
    'phase_started_at',v_phase_started_at,
    'phase_ends_at',v_phase_ends_at,
    'seconds_remaining',greatest(
      0,
      ceil(extract(epoch from (v_phase_ends_at-v_at)))::integer
    )
  );
end;
$function$;

revoke all on function public.jl_aviator_exposure_cycle_state(timestamptz)
from public,anon,authenticated;
grant execute on function public.jl_aviator_exposure_cycle_state(timestamptz)
to service_role;

create or replace function public.jl_aviator_exposure_ratio_at(
  p_at timestamptz default clock_timestamp()
)
returns numeric
language sql
security definer
set search_path to 'pg_catalog','public'
as $function$
  select (
    public.jl_aviator_exposure_cycle_state(p_at)->>'exposure_ratio'
  )::numeric;
$function$;

revoke all on function public.jl_aviator_exposure_ratio_at(timestamptz)
from public,anon,authenticated;
grant execute on function public.jl_aviator_exposure_ratio_at(timestamptz)
to service_role;

create or replace function public.jl_aviator_lock_round(p_round_id bigint)
returns public.jl_aviator_rounds
language plpgsql
security definer
set search_path to 'pg_catalog','public','extensions'
as $function$
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

  select seed
    into v_seed
  from public.jl_aviator_round_secrets
  where round_id=p_round_id;

  v_commit:=encode(extensions.digest(v_seed,'sha256'),'hex');

  if v_round.round_seed_commit<>v_commit then
    raise exception 'Seed nao corresponde ao compromisso pre-aposta';
  end if;

  v_visual:=public.jl_aviator_fairness_visual_target(v_commit);

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

  v_payload:=public.jl_aviator_fairness_lock_payload(
    p_round_id,
    v_commit,
    v_total,
    v_financial,
    v_visual,
    v_locked_effective
  );

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
         fairness_version='JL-AVIATOR-PF-v2'
   where id=p_round_id
  returning * into v_round;

  perform public.jl_aviator_schedule_next_engine_event(p_round_id);
  select * into v_round
  from public.jl_aviator_rounds
  where id=p_round_id;

  return v_round;
end;
$function$;

create or replace function public.jl_aviator_admin_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
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
  v_exposure_ratio numeric:=.25;
  v_risk_ratio numeric:=.25;
  v_exposure_cycle jsonb:='{}'::jsonb;
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

  v_exposure_cycle:=public.jl_aviator_exposure_cycle_state(clock_timestamp());
  v_exposure_ratio:=(v_exposure_cycle->>'exposure_ratio')::numeric;

  v_bank_balance:=coalesce(b.balance,0);
  v_risk_ratio:=case
    when r.id is not null
     and r.status in ('LOCKED','FLYING','CRASHED')
     and r.exposure_ratio_snapshot is not null
      then r.exposure_ratio_snapshot
    else v_exposure_ratio
  end;
  v_risk_budget:=round(greatest(v_bank_balance*v_risk_ratio,0),2);

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
        v_projected_ceiling:=case
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

  v_active_liability:=round(
    greatest(v_active_stake*(v_limit-1),0),
    2
  );

  v_available_after_worst:=round(
    v_bank_balance-v_active_liability,
    2
  );

  v_risk_usage_pct:=case
    when v_risk_budget>0 then round(
      least(greatest(v_active_liability/v_risk_budget*100,0),9999),
      2
    )
    when v_active_liability>0 then 9999
    else 0
  end;

  v_cashout_profit_paid:=round(
    greatest(v_paid-v_cashout_stake,0),
    2
  );

  v_round_house_result:=round(
    v_lost_stake-v_cashout_profit_paid,
    2
  );

  v_house_status:=case
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
      'exposure_ratio',v_exposure_ratio,
      'exposure_cycle',v_exposure_cycle
    ),
    'round',case when r.id is null then null else jsonb_build_object(
      'id',r.id,
      'status',r.status,
      'total_staked',r.total_staked,
      'risk_reserve',r.risk_reserve,
      'financial_ceiling',r.financial_ceiling,
      'exposure_ratio_snapshot',r.exposure_ratio_snapshot,
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
      'risk_ratio',v_risk_ratio,
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

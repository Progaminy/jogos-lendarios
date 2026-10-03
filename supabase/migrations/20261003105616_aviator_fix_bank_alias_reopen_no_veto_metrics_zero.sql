-- Produção aplicada em 2026-10-03 10:56 UTC.
-- Corrige:
-- 1) conflito PL/pgSQL entre o record da banca e alias de aposta ("b.round_id");
-- 2) Reabrir Aviator não pode ser vetado pela certificação;
-- 3) telemetria não deve falhar quando cliente envia round_id/bet_id 0 ou inválido.

create or replace function public.jl_aviator_admin_adjust_bank(
  p_token text,
  p_delta numeric,
  p_reason text,
  p_request_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_bank public.jl_aviator_bank;
  v_existing public.jl_aviator_bank_ledger;
  v_admin uuid:=public.jl_admin_account_id(p_token);
  v_before jsonb;
  v_after jsonb;
  v_reason text:=left(trim(coalesce(p_reason,'')),160);
  v_active_liability numeric:=0;
  v_current_ratio numeric:=0.25;
  v_protected_ratio numeric:=0.25;
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

  perform pg_advisory_xact_lock(
    hashtext('jl_aviator_bank_adjust:'||trim(p_request_key))
  );

  select *
    into v_existing
  from public.jl_aviator_bank_ledger
  where request_key=p_request_key;

  if v_existing.id is not null then
    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'balance',v_existing.balance_after
    );
  end if;

  select *
    into v_bank
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

  if p_delta<0 then
    begin
      v_current_ratio:=coalesce(
        (public.jl_aviator_exposure_cycle_state(clock_timestamp())->>'exposure_ratio')::numeric,
        v_bank.exposure_ratio,
        0.25
      );
    exception
      when others then
        v_current_ratio:=coalesce(v_bank.exposure_ratio,0.25);
    end;

    select
      coalesce(sum(
        greatest(
          bet.stake * (
            greatest(
              coalesce(
                rnd.locked_effective_target,
                rnd.effective_target,
                rnd.visual_target,
                rnd.financial_ceiling,
                1
              ),
              1
            ) - 1
          ),
          0
        )
      ),0),
      coalesce(
        min(coalesce(rnd.exposure_ratio_snapshot,v_current_ratio)),
        v_current_ratio
      )
    into v_active_liability,v_protected_ratio
    from public.jl_aviator_bets bet
    join public.jl_aviator_rounds rnd
      on rnd.id=bet.round_id
    where bet.status='ACTIVE'
      and rnd.status in ('OPEN','LOCKED','FLYING');

    v_active_liability:=round(greatest(coalesce(v_active_liability,0),0),2);
    v_protected_ratio:=greatest(coalesce(v_protected_ratio,v_current_ratio),0);

    if v_active_liability>0 then
      if v_protected_ratio<=0 then
        raise exception 'A banca está totalmente reservada por apostas ativas.';
      end if;

      v_minimum_balance:=
        ceil((v_active_liability/v_protected_ratio)*100)/100;

      if v_new_balance<v_minimum_balance then
        raise exception
          'Ajuste excede o valor livre da banca. Mínimo protegido: % MZN.',
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
    action,details,actor_admin_id,actor_session_id,actor_name,actor_role,
    target_type,target_id,before_state,after_state
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
    'aviator_bank','global',v_before,v_after
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


create or replace function public.jl_aviator_admin_reopen(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_admin uuid:=public.jl_admin_account_id(p_token);
  v_settings public.jl_aviator_settings;
  v_before jsonb;
  v_after jsonb;
  v_round_status text;
begin
  if v_admin is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));

  select *
    into v_settings
  from public.jl_aviator_settings
  where id=true
  for update;

  if coalesce(v_settings.enabled,true) then
    return jsonb_build_object(
      'ok',true,
      'enabled',true,
      'already_open',true,
      'maintenance_message',coalesce(v_settings.maintenance_message,'Aviator brevemente.')
    );
  end if;

  select status
    into v_round_status
  from public.jl_aviator_rounds
  order by id desc
  limit 1;

  v_before:=jsonb_build_object(
    'enabled',coalesce(v_settings.enabled,true),
    'one_round_test',coalesce(v_settings.one_round_test,false),
    'maintenance_message',coalesce(v_settings.maintenance_message,'Aviator brevemente.')
  );

  update public.jl_aviator_settings
     set enabled=true,
         one_round_test=false,
         maintenance_message='Aviator brevemente.',
         updated_at=clock_timestamp()
   where id=true
  returning * into v_settings;

  v_after:=jsonb_build_object(
    'enabled',true,
    'one_round_test',false,
    'maintenance_message',v_settings.maintenance_message,
    'updated_at',v_settings.updated_at
  );

  insert into public.audit_log(
    action,details,actor_admin_id,actor_session_id,actor_name,actor_role,
    target_type,target_id,before_state,after_state
  )
  values(
    'aviator.admin.reopened',
    jsonb_build_object(
      'source','admin_panel',
      'releaseGateEnforced',false,
      'roundInProgress',case
        when v_round_status in ('OPEN','LOCKED','FLYING','CRASHED')
          then v_round_status
        else null
      end
    ),
    v_admin,
    nullif(current_setting('jl.admin_session_id',true),'')::uuid,
    nullif(current_setting('jl.admin_name',true),''),
    nullif(current_setting('jl.admin_role',true),''),
    'aviator_settings','global',v_before,v_after
  );

  return jsonb_build_object(
    'ok',true,
    'enabled',true,
    'already_open',false,
    'maintenance_message',v_settings.maintenance_message,
    'ready_for_new_rounds',true,
    'release_gate_enforced',false,
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


create or replace function public.jl_aviator_record_client_metric(
  p_token text,
  p_operation text,
  p_duration_ms integer,
  p_success boolean,
  p_error_code text default null,
  p_round_id bigint default null,
  p_bet_id bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_player uuid:=public.jl_player_id(p_token);
  v_operation text:=upper(btrim(coalesce(p_operation,'')));
  v_round_id bigint;
  v_bet_id bigint;
begin
  if v_operation not in ('BET','CASHOUT','RECONNECT') then
    raise exception 'Operação de telemetria inválida.';
  end if;

  if p_duration_ms is null or p_duration_ms<0 or p_duration_ms>60000 then
    raise exception 'Latência de telemetria inválida.';
  end if;

  perform public.jl_rate_limit_enforce(
    'aviator_client_metric',v_player::text,60,60,240,300
  );

  if p_round_id is not null
     and p_round_id>0
     and exists(select 1 from public.jl_aviator_rounds rnd where rnd.id=p_round_id) then
    v_round_id:=p_round_id;
  end if;

  if p_bet_id is not null
     and p_bet_id>0
     and exists(
       select 1
       from public.jl_aviator_bets bet
       where bet.id=p_bet_id and bet.player_id=v_player
     ) then
    v_bet_id:=p_bet_id;
  end if;

  insert into public.jl_aviator_client_metrics(
    player_id,operation,duration_ms,success,error_code,round_id,bet_id
  )
  values(
    v_player,v_operation,p_duration_ms,coalesce(p_success,false),
    nullif(left(btrim(coalesce(p_error_code,'')),80),''),
    v_round_id,v_bet_id
  );

  return jsonb_build_object('ok',true);
end;
$function$;

revoke all on function public.jl_aviator_record_client_metric(
  text,text,integer,boolean,text,bigint,bigint
) from public;
grant execute on function public.jl_aviator_record_client_metric(
  text,text,integer,boolean,text,bigint,bigint
) to anon,authenticated,service_role;

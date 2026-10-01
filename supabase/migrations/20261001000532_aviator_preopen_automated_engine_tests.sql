
alter table public.jl_aviator_settings
  add column if not exists last_engine_test_at timestamptz,
  add column if not exists last_engine_test_passed boolean not null default false,
  add column if not exists last_engine_test_version text,
  add column if not exists last_engine_test_checks jsonb not null default '[]'::jsonb,
  add column if not exists last_engine_test_failed_checks jsonb not null default '[]'::jsonb,
  add column if not exists last_engine_test_admin_id uuid;

revoke all on table public.jl_aviator_bets from anon, authenticated;

create or replace function public.jl_aviator_invalidate_engine_test()
returns trigger
language plpgsql
set search_path to 'pg_catalog','public'
as $function$
begin
  if new.one_round_test=true
     or (
       new.enabled=false
       and (
         old.enabled is distinct from new.enabled
         or old.one_round_test is distinct from new.one_round_test
       )
     ) then
    new.last_engine_test_passed:=false;
  end if;

  return new;
end;
$function$;

drop trigger if exists jl_aviator_settings_invalidate_engine_test
on public.jl_aviator_settings;

create trigger jl_aviator_settings_invalidate_engine_test
before update of enabled,one_round_test
on public.jl_aviator_settings
for each row
execute function public.jl_aviator_invalidate_engine_test();

create or replace function public.jl_aviator_admin_engine_preflight(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_admin uuid;
  v_enabled boolean:=true;
  v_one_round_test boolean:=false;
  v_settings_ok boolean:=false;
  v_transient integer:=0;
  v_mismatches integer:=0;
  v_bank_ok boolean:=false;
  v_cron_ok boolean:=false;
  v_functions_ok boolean:=false;
  v_server_clock_ok boolean:=false;
  v_limits_ok boolean:=false;
  v_event_driven_ok boolean:=false;
  v_internal_permissions_ok boolean:=false;
  v_no_direct_dml boolean:=false;
  v_unique_round_ok boolean:=false;
  v_single_bet_ok boolean:=false;
  v_bet_uid_ok boolean:=false;
  v_one_payout_ok boolean:=false;
  v_operation_idempotency_ok boolean:=false;
  v_visual_noise_guard_ok boolean:=false;
  v_place_def text:='';
  v_tick_def text:='';
  v_checks jsonb:='[]'::jsonb;
  v_failed jsonb:='[]'::jsonb;
  v_ok boolean:=false;
  v_passed integer:=0;
  v_total integer:=0;
  v_version text:='preopen-v1';
begin
  perform public.jl_require_admin(p_token);
  v_admin:=public.jl_admin_account_id(p_token);

  perform pg_advisory_xact_lock(hashtext('jl_aviator_engine_tick'));
  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));

  select count(*)=1,
         coalesce(bool_or(enabled),true),
         coalesce(bool_or(one_round_test),false)
    into v_settings_ok,v_enabled,v_one_round_test
  from public.jl_aviator_settings
  where id=true;

  select count(*)
    into v_transient
  from public.jl_aviator_rounds
  where status in ('OPEN','LOCKED','FLYING','CRASHED');

  select count(*)
    into v_mismatches
  from public.players p
  where round(p.balance,2)<>round(public.jl_player_ledger_balance(p.id),2);

  select exists(
    select 1
    from public.jl_aviator_bank b
    where b.id=true
      and b.balance>=0
      and b.exposure_ratio>0
      and b.exposure_ratio<=1
  )
  into v_bank_ok;

  select exists(
    select 1
    from cron.job j
    where j.jobname='jogos_lendarios_engine'
      and j.active
      and j.schedule='2 seconds'
      and lower(j.command) like '%jl_process_game_engine_tick%'
  )
  into v_cron_ok;

  v_functions_ok:=
    pg_catalog.to_regprocedure('public.jl_aviator_place_bet(text,numeric,text,numeric)') is not null
    and pg_catalog.to_regprocedure('public.jl_aviator_cashout(text,bigint,text)') is not null
    and pg_catalog.to_regprocedure('public.jl_aviator_engine_tick()') is not null
    and pg_catalog.to_regprocedure('public.jl_aviator_tick(bigint)') is not null
    and pg_catalog.to_regprocedure('public.jl_process_game_engine_tick()') is not null
    and pg_catalog.to_regprocedure('public.jl_aviator_multiplier(timestamp with time zone,timestamp with time zone)') is not null
    and pg_catalog.to_regprocedure('public.jl_aviator_schedule_next_engine_event(bigint)') is not null
    and pg_catalog.to_regprocedure('public.jl_aviator_player_state(text)') is not null
    and pg_catalog.to_regprocedure('public.jl_aviator_bet_status(text,bigint)') is not null;

  if pg_catalog.to_regprocedure('public.jl_aviator_place_bet(text,numeric,text,numeric)') is not null then
    v_place_def:=lower(pg_catalog.pg_get_functiondef(
      pg_catalog.to_regprocedure('public.jl_aviator_place_bet(text,numeric,text,numeric)')::oid
    ));
  end if;

  if pg_catalog.to_regprocedure('public.jl_process_game_engine_tick()') is not null then
    v_tick_def:=lower(pg_catalog.pg_get_functiondef(
      pg_catalog.to_regprocedure('public.jl_process_game_engine_tick()')::oid
    ));
  end if;

  v_server_clock_ok:=
    position('clock_timestamp()' in v_place_def)>0
    and position('betting_closes_at>v_server_received_at' in replace(v_place_def,' ',''))>0;

  v_limits_ok:=
    position('p_amount<0.50' in replace(v_place_def,' ',''))>0
    and position('p_amount>500' in replace(v_place_def,' ',''))>0;

  v_event_driven_ok:=
    position('engine_due_at' in v_tick_def)>0
    and position('r.engine_due_at<=clock_timestamp()' in replace(v_tick_def,' ',''))>0;

  v_internal_permissions_ok:=
    not pg_catalog.has_function_privilege('anon','public.jl_aviator_tick(bigint)','EXECUTE')
    and not pg_catalog.has_function_privilege('authenticated','public.jl_aviator_tick(bigint)','EXECUTE')
    and not pg_catalog.has_function_privilege('anon','public.jl_aviator_schedule_next_engine_event(bigint)','EXECUTE')
    and not pg_catalog.has_function_privilege('authenticated','public.jl_aviator_schedule_next_engine_event(bigint)','EXECUTE')
    and not pg_catalog.has_function_privilege('anon','public.jl_aviator_lock_round(bigint)','EXECUTE')
    and not pg_catalog.has_function_privilege('authenticated','public.jl_aviator_lock_round(bigint)','EXECUTE')
    and not pg_catalog.has_function_privilege('anon','public.jl_aviator_start_round(bigint)','EXECUTE')
    and not pg_catalog.has_function_privilege('authenticated','public.jl_aviator_start_round(bigint)','EXECUTE')
    and not pg_catalog.has_function_privilege('anon','public.jl_aviator_cashout_core(text,bigint)','EXECUTE')
    and not pg_catalog.has_function_privilege('authenticated','public.jl_aviator_cashout_core(text,bigint)','EXECUTE');

  select not exists(
    select 1
    from information_schema.role_table_grants g
    where g.table_schema='public'
      and g.table_name in ('jl_aviator_bets','transactions')
      and g.grantee in ('anon','authenticated')
      and g.privilege_type in ('SELECT','INSERT','UPDATE','DELETE','TRUNCATE')
  )
  into v_no_direct_dml;

  select exists(
    select 1 from pg_indexes
    where schemaname='public'
      and tablename='jl_aviator_rounds'
      and indexname='jl_aviator_one_transitional_round_idx'
      and lower(indexdef) like 'create unique index%'
  ) into v_unique_round_ok;

  select exists(
    select 1 from pg_indexes
    where schemaname='public'
      and tablename='jl_aviator_bets'
      and indexname='jl_aviator_bets_player_round_uidx'
      and lower(indexdef) like 'create unique index%'
  ) into v_single_bet_ok;

  select exists(
    select 1 from pg_indexes
    where schemaname='public'
      and tablename='jl_aviator_bets'
      and indexname='jl_aviator_bets_bet_uid_uidx'
      and lower(indexdef) like 'create unique index%'
  ) into v_bet_uid_ok;

  select exists(
    select 1 from pg_indexes
    where schemaname='public'
      and tablename='transactions'
      and indexname='transactions_one_aviator_payout_per_bet'
      and lower(indexdef) like 'create unique index%'
  ) into v_one_payout_ok;

  select exists(
    select 1 from pg_indexes
    where schemaname='public'
      and tablename='transactions'
      and indexname='transactions_aviator_bet_operation_uidx'
      and lower(indexdef) like 'create unique index%'
  ) into v_operation_idempotency_ok;

  select exists(
    select 1
    from pg_constraint c
    where c.conrelid='public.audit_log'::regclass
      and c.conname='audit_log_no_aviator_visual_noise'
  )
  into v_visual_noise_guard_ok;

  v_checks:=jsonb_build_array(
    jsonb_build_object('id','aviator_closed','ok',not v_enabled and not v_one_round_test,'detail','Aviator deve estar fechado e fora do teste de 1 rodada'),
    jsonb_build_object('id','settings_singleton','ok',v_settings_ok,'detail','Configuração global do Aviator presente'),
    jsonb_build_object('id','no_transient_round','ok',v_transient=0,'detail','Nenhuma rodada OPEN/LOCKED/FLYING/CRASHED'),
    jsonb_build_object('id','engine_cron','ok',v_cron_ok,'detail','Cron do motor ativo a cada 2 segundos'),
    jsonb_build_object('id','critical_functions','ok',v_functions_ok,'detail','Funções críticas do motor disponíveis'),
    jsonb_build_object('id','server_clock_gate','ok',v_server_clock_ok,'detail','Janela de aposta usa relógio do servidor'),
    jsonb_build_object('id','bet_limits','ok',v_limits_ok,'detail','Limites 0,50–500 MZN estão no RPC autoritativo'),
    jsonb_build_object('id','event_driven_engine','ok',v_event_driven_ok,'detail','Voo usa engine_due_at em vez de tick pesado contínuo'),
    jsonb_build_object('id','internal_permissions','ok',v_internal_permissions_ok,'detail','Funções internas não executáveis por jogador'),
    jsonb_build_object('id','no_direct_financial_dml','ok',v_no_direct_dml,'detail','Cliente não altera apostas/transações diretamente'),
    jsonb_build_object('id','one_transitional_round','ok',v_unique_round_ok,'detail','Banco garante uma única rodada transitória'),
    jsonb_build_object('id','one_bet_per_round','ok',v_single_bet_ok,'detail','Banco garante uma aposta por jogador/rodada'),
    jsonb_build_object('id','unique_bet_id','ok',v_bet_uid_ok,'detail','Identificador único de aposta garantido'),
    jsonb_build_object('id','one_payout_per_bet','ok',v_one_payout_ok,'detail','Payout único por aposta garantido'),
    jsonb_build_object('id','financial_idempotency','ok',v_operation_idempotency_ok,'detail','Operação financeira única por aposta/tipo'),
    jsonb_build_object('id','ledger_balance_match','ok',v_mismatches=0,'detail','Saldo exibido coincide com ledger imutável'),
    jsonb_build_object('id','bank_valid','ok',v_bank_ok,'detail','Banca e exposição em faixa válida'),
    jsonb_build_object('id','no_visual_audit_noise','ok',v_visual_noise_guard_ok,'detail','Frames/ticks visuais não entram no audit')
  );

  select coalesce(jsonb_agg(to_jsonb(x.id) order by x.id),'[]'::jsonb)
    into v_failed
  from (
    select e->>'id' as id
    from jsonb_array_elements(v_checks) e
    where coalesce((e->>'ok')::boolean,false)=false
  ) x;

  v_total:=jsonb_array_length(v_checks);
  v_passed:=v_total-jsonb_array_length(v_failed);
  v_ok:=jsonb_array_length(v_failed)=0;

  update public.jl_aviator_settings
     set last_engine_test_at=clock_timestamp(),
         last_engine_test_passed=v_ok,
         last_engine_test_version=v_version,
         last_engine_test_checks=v_checks,
         last_engine_test_failed_checks=v_failed,
         last_engine_test_admin_id=v_admin
   where id=true;

  insert into public.audit_log(
    action,details,actor_admin_id,target_type,target_id
  )
  values(
    case when v_ok
      then 'aviator.admin.engine_preflight_passed'
      else 'aviator.admin.engine_preflight_failed'
    end,
    jsonb_build_object(
      'version',v_version,
      'passed',v_passed,
      'total',v_total,
      'failedChecks',v_failed,
      'testedAt',clock_timestamp()
    ),
    v_admin,
    'aviator_engine',
    'global'
  );

  return jsonb_build_object(
    'ok',v_ok,
    'version',v_version,
    'passed',v_passed,
    'total',v_total,
    'failed_checks',v_failed,
    'checks',v_checks,
    'tested_at',(select last_engine_test_at from public.jl_aviator_settings where id=true)
  );
end;
$function$;

revoke execute on function public.jl_aviator_admin_engine_preflight(text)
from public;

grant execute on function public.jl_aviator_admin_engine_preflight(text)
to anon,authenticated,service_role;

create or replace function public.jl_aviator_admin_engine_test_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  s public.jl_aviator_settings;
begin
  perform public.jl_require_admin(p_token);

  select * into s
  from public.jl_aviator_settings
  where id=true;

  return jsonb_build_object(
    'passed',coalesce(s.last_engine_test_passed,false),
    'tested_at',s.last_engine_test_at,
    'version',s.last_engine_test_version,
    'checks',coalesce(s.last_engine_test_checks,'[]'::jsonb),
    'failed_checks',coalesce(s.last_engine_test_failed_checks,'[]'::jsonb)
  );
end;
$function$;

revoke execute on function public.jl_aviator_admin_engine_test_state(text)
from public;

grant execute on function public.jl_aviator_admin_engine_test_state(text)
to anon,authenticated,service_role;


CREATE OR REPLACE FUNCTION public.jl_aviator_admin_set_enabled(p_token text, p_enabled boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s public.jl_aviator_settings;
  v_admin uuid:=public.jl_admin_account_id(p_token);
  v_resolution jsonb:=jsonb_build_object('action','NONE');
  v_before jsonb;
  v_after jsonb;
  v_action text;
  v_preflight jsonb;
begin
  if v_admin is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  if p_enabled is null then
    raise exception 'Estado de manutencao invalido.';
  end if;

  perform pg_advisory_xact_lock(hashtext('jl_aviator_engine_tick'));
  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));

  if p_enabled then
    v_preflight:=public.jl_aviator_admin_engine_preflight(p_token);

    if coalesce((v_preflight->>'ok')::boolean,false) is distinct from true then
      raise exception 'Testes automáticos do motor falharam: %',
        coalesce(v_preflight->'failed_checks','[]'::jsonb)::text;
    end if;
  end if;

  select jsonb_build_object(
    'enabled',coalesce(enabled,true),
    'one_round_test',coalesce(one_round_test,false),
    'maintenance_message',coalesce(maintenance_message,'Aviator brevemente.')
  )
  into v_before
  from public.jl_aviator_settings
  where id=true
  for update;

  v_before:=coalesce(
    v_before,
    jsonb_build_object(
      'enabled',true,
      'one_round_test',false,
      'maintenance_message','Aviator brevemente.'
    )
  );

  insert into public.jl_aviator_settings(
    id,enabled,one_round_test,maintenance_message,updated_at
  )
  values(
    true,p_enabled,false,'Aviator brevemente.',clock_timestamp()
  )
  on conflict(id) do update
    set enabled=excluded.enabled,
        one_round_test=false,
        maintenance_message='Aviator brevemente.',
        updated_at=excluded.updated_at
  returning * into s;

  if not p_enabled then
    v_resolution:=public.jl_aviator_engine_tick();
  end if;

  v_after:=jsonb_build_object(
    'enabled',s.enabled,
    'one_round_test',coalesce(s.one_round_test,false),
    'maintenance_message',coalesce(s.maintenance_message,'Aviator brevemente.'),
    'updated_at',s.updated_at
  );

  v_action:=case
    when p_enabled then 'aviator.admin.reopened'
    else 'aviator.admin.closed'
  end;

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
    v_action,
    jsonb_build_object(
      'resolution',v_resolution,
      'source','admin_panel'
    ),
    v_admin,
    nullif(current_setting('jl.admin_session_id',true),'')::uuid,
    nullif(current_setting('jl.admin_name',true),''),
    nullif(current_setting('jl.admin_role',true),''),
    'aviator_settings',
    'global',
    v_before,
    v_after
  );

  return jsonb_build_object(
    'ok',true,
    'enabled',s.enabled,
    'one_round_test',false,
    'maintenance_message','Aviator brevemente.',
    'resolution',v_resolution,
    'engine_test',v_preflight
  );
end
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_admin_reopen(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_state jsonb;
  v_round jsonb;
  v_status text;
  v_enable_result jsonb;
begin
  perform pg_advisory_xact_lock(hashtext('jl_aviator_engine_tick'));
  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));

  v_state:=public.jl_aviator_admin_state(p_token);

  if coalesce((v_state->>'enabled')::boolean,false) then
    return jsonb_build_object(
      'ok',true,
      'enabled',true,
      'already_open',true,
      'maintenance_message','Aviator brevemente.'
    );
  end if;

  v_round:=v_state->'round';
  v_status:=v_round->>'status';

  if coalesce(v_status in ('OPEN','LOCKED','FLYING','CRASHED'),false) then
    raise exception 'Aguarde a rodada atual terminar antes de reabrir o Aviator.';
  end if;

  v_enable_result:=public.jl_aviator_admin_set_enabled(p_token,true);

  return jsonb_build_object(
    'ok',true,
    'enabled',true,
    'already_open',false,
    'maintenance_message','Aviator brevemente.',
    'ready_for_new_rounds',true,
    'engine_test',v_enable_result->'engine_test'
  );
end
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_admin_start_one_round_test(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_live integer;
  v_bank numeric;
  v_enabled boolean;
  v_test boolean;
  v_admin uuid:=public.jl_admin_account_id(p_token);
  v_before jsonb;
  v_after jsonb;
  v_preflight jsonb;
begin
  if v_admin is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  perform pg_advisory_xact_lock(hashtext('jl_aviator_engine_tick'));
  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));

  select enabled,one_round_test,
         jsonb_build_object(
           'enabled',coalesce(enabled,true),
           'one_round_test',coalesce(one_round_test,false)
         )
    into v_enabled,v_test,v_before
  from public.jl_aviator_settings
  where id=true
  for update;

  if coalesce(v_enabled,false) or coalesce(v_test,false) then
    raise exception 'Feche o Aviator antes de iniciar uma rodada de teste.';
  end if;

  select count(*)
    into v_live
  from public.jl_aviator_rounds
  where status in ('OPEN','LOCKED','FLYING','CRASHED');

  if v_live<>0 then
    raise exception 'Existe uma rodada Aviator em andamento.';
  end if;

  v_preflight:=public.jl_aviator_admin_engine_preflight(p_token);

  if coalesce((v_preflight->>'ok')::boolean,false) is distinct from true then
    raise exception 'Testes automáticos do motor falharam: %',
      coalesce(v_preflight->'failed_checks','[]'::jsonb)::text;
  end if;

  select balance
    into v_bank
  from public.jl_aviator_bank
  where id=true
  for update;

  update public.jl_aviator_settings
     set enabled=true,
         one_round_test=true,
         updated_at=clock_timestamp()
   where id=true;

  v_after:=jsonb_build_object(
    'enabled',true,
    'one_round_test',true,
    'bank_balance',v_bank,
    'engine_test',v_preflight
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
    'aviator.admin.one_round_test_started',
    jsonb_build_object(
      'bankBalance',v_bank,
      'startedAt',clock_timestamp()
    ),
    v_admin,
    nullif(current_setting('jl.admin_session_id',true),'')::uuid,
    nullif(current_setting('jl.admin_name',true),''),
    nullif(current_setting('jl.admin_role',true),''),
    'aviator_settings',
    'global',
    v_before,
    v_after
  );

  return jsonb_build_object(
    'ok',true,
    'enabled',true,
    'one_round_test',true,
    'bank_balance',v_bank
  );
end
$function$;

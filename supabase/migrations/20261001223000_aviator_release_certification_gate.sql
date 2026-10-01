-- Aviator ponto 67:
-- o jogo real só pode reabrir após certificação repetida do fluxo completo.
-- A sonda roda em subtransações descartáveis: nenhum dinheiro/jogador/rodada de
-- teste permanece gravado depois da certificação.

alter table public.jl_aviator_settings
  add column if not exists last_release_gate_at timestamptz,
  add column if not exists last_release_gate_passed boolean not null default false,
  add column if not exists last_release_gate_version text,
  add column if not exists last_release_gate_result jsonb not null default '{}'::jsonb,
  add column if not exists last_release_gate_admin_id uuid;

create or replace function public.jl_aviator_release_flow_probe(
  p_iterations integer default 3
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_iterations integer:=least(10,greatest(3,coalesce(p_iterations,3)));
  v_i integer;
  v_passed integer:=0;
  v_failures jsonb:='[]'::jsonb;
  v_error text;
  v_marker constant text:='__AVIATOR_RELEASE_PROBE_ROLLBACK_OK__';
  v_p_cash uuid;
  v_p_loss uuid;
  v_t_cash text;
  v_t_loss text;
  v_round bigint;
  v_b_cash jsonb;
  v_b_loss jsonb;
  v_cash jsonb;
  v_tick jsonb;
  v_snap jsonb;
  v_hist jsonb;
  v_bet jsonb;
  v_consistency jsonb;
begin
  if exists(
    select 1
    from public.jl_aviator_rounds
    where status in ('OPEN','LOCKED','FLYING','CRASHED')
  ) then
    return jsonb_build_object(
      'ok',false,
      'iterations',v_iterations,
      'passed',0,
      'failed_checks',jsonb_build_array('transient_round_present'),
      'message','Existe uma rodada em andamento.'
    );
  end if;

  for v_i in 1..v_iterations loop
    v_error:=null;

    begin
      update public.jl_aviator_settings
         set enabled=true,
             one_round_test=false,
             updated_at=clock_timestamp()
       where id=true;

      update public.jl_aviator_bank
         set balance=100000,
             exposure_ratio=.5,
             updated_at=clock_timestamp()
       where id=true;

      v_t_cash:='release-probe-cash-'||v_i::text||'-'||gen_random_uuid()::text;
      v_t_loss:='release-probe-loss-'||v_i::text||'-'||gen_random_uuid()::text;

      insert into public.players(name,phone,pin_hash,balance)
      values(
        'AVIATOR RELEASE PROBE CASH',
        'release-cash-'||gen_random_uuid()::text,
        'test-only',
        100
      )
      returning id into v_p_cash;

      insert into public.players(name,phone,pin_hash,balance)
      values(
        'AVIATOR RELEASE PROBE LOSS',
        'release-loss-'||gen_random_uuid()::text,
        'test-only',
        100
      )
      returning id into v_p_loss;

      insert into public.transactions(id,player_id,kind,amount,status,note)
      values
        (gen_random_uuid(),v_p_cash,'deposit',100,'completed','Aviator release probe funding'),
        (gen_random_uuid(),v_p_loss,'deposit',100,'completed','Aviator release probe funding');

      insert into public.player_sessions(player_id,token_hash,expires_at)
      values
        (v_p_cash,public.jl_token_hash(v_t_cash),clock_timestamp()+interval '1 hour'),
        (v_p_loss,public.jl_token_hash(v_t_loss),clock_timestamp()+interval '1 hour');

      insert into public.jl_aviator_rounds(
        status,betting_closes_at,takeoff_at
      )
      values(
        'OPEN',
        clock_timestamp()+interval '30 seconds',
        clock_timestamp()+interval '33 seconds'
      )
      returning id into v_round;

      v_b_cash:=public.jl_aviator_place_bet(
        v_t_cash,10,'release-probe-cash-'||v_round::text,null
      );

      v_b_loss:=public.jl_aviator_place_bet(
        v_t_loss,10,'release-probe-loss-'||v_round::text,null
      );

      perform public.jl_aviator_lock_round(v_round);

      update public.jl_aviator_rounds
         set betting_closes_at=clock_timestamp()-interval '8 seconds',
             takeoff_at=clock_timestamp()-interval '5 seconds'
       where id=v_round;

      perform public.jl_aviator_start_round(v_round);

      update public.jl_aviator_rounds
         set started_at=clock_timestamp()-interval '1 second',
             financial_ceiling=5.00,
             locked_effective_target=5.00,
             effective_target=5.00,
             visual_extension=false,
             engine_due_at=clock_timestamp()+interval '10 minutes'
       where id=v_round;

      -- reconexão durante voo deve recuperar a aposta ativa.
      v_snap:=public.jl_aviator_reconnect(v_t_cash);

      if v_snap->'round'->>'status'<>'FLYING' then
        raise exception 'reconnect não recuperou FLYING';
      end if;

      select value into v_bet
      from jsonb_array_elements(v_snap->'player'->'bets')
      where (value->>'id')::bigint=(v_b_cash->>'bet_id')::bigint;

      if v_bet is null or v_bet->>'status'<>'ACTIVE' then
        raise exception 'reconnect perdeu aposta ACTIVE';
      end if;

      -- caminho cash-out.
      v_cash:=public.jl_aviator_cashout(
        v_t_cash,
        (v_b_cash->>'bet_id')::bigint,
        'release-probe-out-'||v_round::text
      );

      if coalesce((v_cash->>'ok')::boolean,false) is distinct from true then
        raise exception 'cash-out falhou: %',v_cash;
      end if;

      if not exists(
        select 1
        from public.jl_aviator_bets b
        join public.transactions t on t.id=b.payout_transaction_id
        where b.id=(v_b_cash->>'bet_id')::bigint
          and b.status='CASHED_OUT'
          and t.aviator_operation='PAYOUT'
          and round(t.amount,2)=round(b.payout,2)
      ) then
        raise exception 'pagamento do cash-out não fechou';
      end if;

      -- caminho crash: a segunda aposta permanece ativa até perder.
      update public.jl_aviator_rounds
         set started_at=clock_timestamp()-interval '20 seconds',
             financial_ceiling=2.00,
             locked_effective_target=2.00,
             effective_target=2.00,
             visual_extension=false,
             engine_due_at=clock_timestamp()
       where id=v_round;

      v_tick:=public.jl_aviator_tick(v_round);

      if v_tick->>'status'<>'CRASHED' then
        raise exception 'motor não chegou a CRASHED: %',v_tick;
      end if;

      v_tick:=public.jl_aviator_engine_tick();

      if v_tick->>'status'<>'SETTLED' then
        raise exception 'motor não chegou a SETTLED: %',v_tick;
      end if;

      if not exists(
        select 1
        from public.jl_aviator_bets
        where id=(v_b_loss->>'bet_id')::bigint
          and status='LOST'
          and payout=0
      ) then
        raise exception 'aposta do caminho crash não terminou LOST';
      end if;

      -- reconexão após fim deve trazer a perda verdadeira.
      v_snap:=public.jl_aviator_reconnect(v_t_loss);

      select value into v_bet
      from jsonb_array_elements(v_snap->'player'->'bets')
      where (value->>'id')::bigint=(v_b_loss->>'bet_id')::bigint;

      if v_bet is null or v_bet->>'status'<>'LOST' then
        raise exception 'reconnect pós-crash não trouxe LOST';
      end if;

      -- histórico precisa refletir cash-out e crash.
      v_hist:=public.jl_aviator_my_history(v_t_cash,20,null);
      if not exists(
        select 1
        from jsonb_array_elements(v_hist->'bets') h
        where (h->>'id')::bigint=(v_b_cash->>'bet_id')::bigint
          and h->>'status'='CASHED_OUT'
      ) then
        raise exception 'histórico não trouxe CASHED_OUT';
      end if;

      v_hist:=public.jl_aviator_my_history(v_t_loss,20,null);
      if not exists(
        select 1
        from jsonb_array_elements(v_hist->'bets') h
        where (h->>'id')::bigint=(v_b_loss->>'bet_id')::bigint
          and h->>'status'='LOST'
      ) then
        raise exception 'histórico não trouxe LOST';
      end if;

      v_consistency:=public.jl_aviator_financial_consistency_snapshot();
      if coalesce((v_consistency->>'ok')::boolean,false) is distinct from true then
        raise exception 'divergência financeira na sonda: %',v_consistency;
      end if;

      -- força rollback de toda a iteração bem-sucedida.
      raise exception '%',v_marker;
    exception
      when others then
        v_error:=sqlerrm;
    end;

    if v_error=v_marker then
      v_passed:=v_passed+1;
    else
      v_failures:=v_failures||jsonb_build_array(
        jsonb_build_object(
          'iteration',v_i,
          'error',coalesce(v_error,'falha desconhecida')
        )
      );
    end if;
  end loop;

  return jsonb_build_object(
    'ok',v_passed=v_iterations,
    'iterations',v_iterations,
    'passed',v_passed,
    'failed',v_iterations-v_passed,
    'failures',v_failures
  );
end;
$function$;

revoke all on function public.jl_aviator_release_flow_probe(integer)
from public,anon,authenticated;
grant execute on function public.jl_aviator_release_flow_probe(integer)
to service_role;

create or replace function public.jl_aviator_admin_release_gate(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_admin uuid;
  v_structural jsonb;
  v_flow jsonb;
  v_financial jsonb;
  v_ok boolean:=false;
  v_result jsonb;
  v_version text:='release-gate-v1';
begin
  perform public.jl_require_admin(p_token);
  v_admin:=public.jl_admin_account_id(p_token);

  v_structural:=public.jl_aviator_admin_engine_preflight(p_token);
  v_financial:=public.jl_aviator_financial_consistency_watch();

  if coalesce((v_structural->>'ok')::boolean,false)
     and coalesce((v_financial->>'ok')::boolean,false) then
    v_flow:=public.jl_aviator_release_flow_probe(3);
  else
    v_flow:=jsonb_build_object(
      'ok',false,
      'iterations',3,
      'passed',0,
      'skipped',true
    );
  end if;

  v_ok:=
    coalesce((v_structural->>'ok')::boolean,false)
    and coalesce((v_financial->>'ok')::boolean,false)
    and coalesce((v_flow->>'ok')::boolean,false);

  v_result:=jsonb_build_object(
    'ok',v_ok,
    'version',v_version,
    'structural',v_structural,
    'financial_consistency',v_financial,
    'repeated_flow',v_flow,
    'tested_at',clock_timestamp()
  );

  update public.jl_aviator_settings
     set last_release_gate_at=clock_timestamp(),
         last_release_gate_passed=v_ok,
         last_release_gate_version=v_version,
         last_release_gate_result=v_result,
         last_release_gate_admin_id=v_admin
   where id=true;

  insert into public.audit_log(
    action,details,actor_admin_id,target_type,target_id
  )
  values(
    case when v_ok
      then 'aviator.admin.release_gate_passed'
      else 'aviator.admin.release_gate_failed'
    end,
    v_result,
    v_admin,
    'aviator_release_gate',
    'global'
  );

  return v_result;
end;
$function$;

revoke all on function public.jl_aviator_admin_release_gate(text)
from public;
grant execute on function public.jl_aviator_admin_release_gate(text)
to anon,authenticated,service_role;

create or replace function public.jl_aviator_admin_release_gate_state(p_token text)
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
    'passed',coalesce(s.last_release_gate_passed,false),
    'tested_at',s.last_release_gate_at,
    'version',s.last_release_gate_version,
    'result',coalesce(s.last_release_gate_result,'{}'::jsonb)
  );
end;
$function$;

revoke all on function public.jl_aviator_admin_release_gate_state(text)
from public;
grant execute on function public.jl_aviator_admin_release_gate_state(text)
to anon,authenticated,service_role;

-- Enforce the full release gate on real opening.
alter function public.jl_aviator_admin_set_enabled(text,boolean)
  rename to jl_aviator_admin_set_enabled_core;

create or replace function public.jl_aviator_admin_set_enabled(
  p_token text,
  p_enabled boolean
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_gate jsonb;
  v_result jsonb;
begin
  if p_enabled is true then
    v_gate:=public.jl_aviator_admin_release_gate(p_token);

    if coalesce((v_gate->>'ok')::boolean,false) is distinct from true then
      raise exception 'Certificação completa do Aviator falhou. O jogo permanece fechado.';
    end if;
  end if;

  v_result:=public.jl_aviator_admin_set_enabled_core(p_token,p_enabled);

  if p_enabled is true then
    return v_result||jsonb_build_object('release_gate',v_gate);
  end if;

  return v_result;
end;
$function$;

revoke all on function public.jl_aviator_admin_set_enabled(text,boolean)
from public;
grant execute on function public.jl_aviator_admin_set_enabled(text,boolean)
to anon,authenticated,service_role;

revoke all on function public.jl_aviator_admin_set_enabled_core(text,boolean)
from public,anon,authenticated;
grant execute on function public.jl_aviator_admin_set_enabled_core(text,boolean)
to service_role;

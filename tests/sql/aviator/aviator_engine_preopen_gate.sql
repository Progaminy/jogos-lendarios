-- Ponto 54: abertura real do Aviator exige preflight automatizado do motor.
begin;

update public.jl_aviator_rounds
   set status='CANCELLED',
       settled_at=coalesce(settled_at,clock_timestamp())
 where status in ('OPEN','LOCKED','FLYING','CRASHED');

update public.jl_aviator_settings
   set enabled=false,
       one_round_test=false
 where id=true;

do $test$
declare
  v_admin uuid;
  v_token text:='preopen-gate-'||gen_random_uuid()::text;
  v_result jsonb;
  v_open jsonb;
  v_blocked boolean:=false;
  v_enabled boolean;
begin
  insert into public.admin_accounts(display_name,role,code_hash,code_scheme,active)
  values('AVIATOR PREOPEN GATE TEST','admin','test-hash','bcrypt',true)
  returning id into v_admin;

  insert into public.admin_sessions(admin_id,token_hash,expires_at)
  values(v_admin,public.jl_token_hash(v_token),clock_timestamp()+interval '1 hour');

  v_result:=public.jl_aviator_admin_engine_preflight(v_token);

  if coalesce((v_result->>'ok')::boolean,false) is distinct from true then
    raise exception 'preflight limpo deveria passar: %',v_result;
  end if;

  if (v_result->>'passed')::integer<>(v_result->>'total')::integer then
    raise exception 'todos os checks deveriam passar: %',v_result;
  end if;

  if (v_result->>'total')::integer<18 then
    raise exception 'suite preopen encolheu abaixo de 18 checks: %',v_result;
  end if;

  v_open:=public.jl_aviator_admin_reopen(v_token);

  if coalesce((v_open->>'enabled')::boolean,false) is distinct from true then
    raise exception 'reabertura válida falhou: %',v_open;
  end if;

  if coalesce((v_open->'engine_test'->>'ok')::boolean,false) is distinct from true then
    raise exception 'reabertura não retornou certificação aprovada: %',v_open;
  end if;

  perform public.jl_aviator_admin_set_enabled(v_token,false);

  alter table public.transactions
    drop constraint transactions_one_aviator_payout_per_bet;

  v_result:=public.jl_aviator_admin_engine_preflight(v_token);

  if coalesce((v_result->>'ok')::boolean,true) is distinct from false then
    raise exception 'preflight deveria falhar sem payout único: %',v_result;
  end if;

  if not (v_result->'failed_checks') ? 'one_payout_per_bet' then
    raise exception 'one_payout_per_bet deveria aparecer nas falhas: %',v_result;
  end if;

  begin
    perform public.jl_aviator_admin_set_enabled(v_token,true);
  exception
    when others then
      if position('Certificação completa do Aviator falhou' in sqlerrm)>0
         or position('Testes automáticos do motor falharam' in sqlerrm)>0 then
        v_blocked:=true;
      else
        raise;
      end if;
  end;

  if not v_blocked then
    raise exception 'admin_set_enabled(true) contornou preflight';
  end if;

  select enabled into v_enabled
  from public.jl_aviator_settings
  where id=true;

  if v_enabled is distinct from false then
    raise exception 'Aviator abriu mesmo com preflight falhando';
  end if;

  if not exists(
    select 1
    from public.audit_log
    where action='aviator.admin.engine_preflight_failed'
      and actor_admin_id=v_admin
  ) then
    raise exception 'falha de preflight não foi auditada';
  end if;
end
$test$;

rollback;

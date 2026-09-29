-- Aviator: modo operacional de uma unica rodada real.
-- O admin pode abrir exatamente uma rodada para validacao.
-- Depois de SETTLED, o backend volta automaticamente para manutencao
-- antes que outra rodada seja criada.

alter table public.jl_aviator_settings
  add column if not exists one_round_test boolean not null default false;

create or replace function public.jl_aviator_admin_start_one_round_test(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_live integer;
  v_bank numeric;
  v_enabled boolean;
  v_test boolean;
  v_admin uuid:=public.jl_admin_account_id(p_token);
begin
  if v_admin is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;
  perform pg_advisory_xact_lock(hashtext('jl_aviator_engine_tick'));
  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));

  select enabled,one_round_test
    into v_enabled,v_test
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

  insert into public.audit_log(action,details)
  values(
    'aviator.one_round_test_started',
    jsonb_build_object(
      'bankBalance',v_bank,
      'startedAt',clock_timestamp(),
      'admin_id',v_admin,
      'admin_session_id',nullif(current_setting('jl.admin_session_id',true),''),
      'admin_name',nullif(current_setting('jl.admin_name',true),''),
      'admin_role',nullif(current_setting('jl.admin_role',true),'')
    )
  );

  return jsonb_build_object(
    'ok',true,
    'enabled',true,
    'one_round_test',true,
    'bank_balance',v_bank
  );
end
$$;

revoke all on function public.jl_aviator_admin_start_one_round_test(text)
from public;

grant execute on function public.jl_aviator_admin_start_one_round_test(text)
to anon,authenticated;

-- Toggle manual sempre cancela o modo one-shot.
create or replace function public.jl_aviator_admin_set_enabled(
  p_token text,
  p_enabled boolean
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  s public.jl_aviator_settings;
  v_cancelled bigint:=0;
  v_admin uuid:=public.jl_admin_account_id(p_token);
begin
  if v_admin is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  if p_enabled is null then
    raise exception 'Estado de manutencao invalido.';
  end if;

  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));

  insert into public.jl_aviator_settings(id,enabled,one_round_test,updated_at)
  values(true,p_enabled,false,now())
  on conflict(id) do update
    set enabled=excluded.enabled,
        one_round_test=false,
        updated_at=excluded.updated_at
  returning * into s;

  if not p_enabled then
    update public.jl_aviator_rounds r
       set status='CANCELLED',
           settled_at=coalesce(r.settled_at,now())
     where r.status='OPEN'
       and not exists(
         select 1
         from public.jl_aviator_bets b
         where b.round_id=r.id
           and b.status='ACTIVE'
       );

    get diagnostics v_cancelled = row_count;
  end if;

  insert into public.audit_log(action,details)
  values(
    'aviator.maintenance_changed',
    jsonb_build_object(
      'enabled',s.enabled,
      'updatedAt',s.updated_at,
      'emptyOpenRoundsCancelled',v_cancelled,
      'oneRoundTest',false,
      'admin_id',v_admin,
      'admin_session_id',nullif(current_setting('jl.admin_session_id',true),''),
      'admin_name',nullif(current_setting('jl.admin_name',true),''),
      'admin_role',nullif(current_setting('jl.admin_role',true),'')
    )
  );

  return jsonb_build_object(
    'ok',true,
    'enabled',s.enabled,
    'one_round_test',false,
    'maintenance_message',s.maintenance_message,
    'empty_open_rounds_cancelled',v_cancelled
  );
end
$$;

revoke all on function public.jl_aviator_admin_set_enabled(text,boolean) from public;
grant execute on function public.jl_aviator_admin_set_enabled(text,boolean) to anon,authenticated;

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
  v_staked numeric:=0;
  v_paid numeric:=0;
begin
  perform public.jl_require_admin(p_token);

  select * into b from public.jl_aviator_bank where id=true;
  select * into s from public.jl_aviator_settings where id=true;
  select * into r from public.jl_aviator_rounds order by id desc limit 1;

  if r.id is not null then
    select count(*),coalesce(sum(stake),0),coalesce(sum(payout),0)
      into v_bets,v_staked,v_paid
    from public.jl_aviator_bets
    where round_id=r.id;
  end if;

  return jsonb_build_object(
    'enabled',coalesce(s.enabled,true),
    'one_round_test',coalesce(s.one_round_test,false),
    'maintenance_message',coalesce(s.maintenance_message,'Aviator em manutencao. Volte em breve.'),
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
    'bets',v_bets,
    'stake_sum',v_staked,
    'paid_sum',v_paid
  );
end
$$;

revoke all on function public.jl_aviator_admin_state(text) from public;
grant execute on function public.jl_aviator_admin_state(text) to anon,authenticated;

create or replace function public.jl_aviator_engine_tick()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  r public.jl_aviator_rounds;
  result jsonb;
  v_enabled boolean:=true;
  v_active int:=0;
  v_one_round_test boolean:=false;
begin
  perform pg_advisory_xact_lock(hashtext('jl_aviator_engine_tick'));
  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));

  select coalesce(enabled,true),coalesce(one_round_test,false)
    into v_enabled,v_one_round_test
  from public.jl_aviator_settings
  where id=true;

  select *
    into r
  from public.jl_aviator_rounds
  where status in ('OPEN','LOCKED','FLYING','CRASHED')
  order by id desc
  limit 1
  for update;

  if r.id is null then
    if not v_enabled then
      return jsonb_build_object('action','WAIT','maintenance',true);
    end if;
    return public.jl_aviator_open_next_if_due();
  end if;

  if r.status='OPEN' then
    select count(*)
      into v_active
    from public.jl_aviator_bets
    where round_id=r.id
      and status='ACTIVE';

    if not v_enabled and v_active=0 then
      update public.jl_aviator_rounds
         set status='CANCELLED',
             settled_at=coalesce(settled_at,now())
       where id=r.id;

      return jsonb_build_object(
        'action','CANCELLED_EMPTY_OPEN',
        'round_id',r.id,
        'maintenance',true
      );
    end if;

    if r.betting_closes_at is not null and now()>=r.betting_closes_at then
      perform public.jl_aviator_lock_round(r.id);

      update public.jl_aviator_rounds
         set status='FLYING',
             started_at=clock_timestamp()
       where id=r.id;

      return jsonb_build_object(
        'action','STARTED',
        'round_id',r.id,
        'maintenance',not v_enabled,
        'one_round_test',v_one_round_test
      );
    end if;

    return jsonb_build_object(
      'action','WAIT',
      'round_id',r.id,
      'status',r.status,
      'maintenance',not v_enabled,
      'one_round_test',v_one_round_test
    );
  end if;

  if r.status='LOCKED' then
    update public.jl_aviator_rounds
       set status='FLYING',
           started_at=coalesce(started_at,clock_timestamp())
     where id=r.id
     returning * into r;

    return jsonb_build_object(
      'action','RECOVERED_LOCKED',
      'round_id',r.id,
      'status',r.status,
      'maintenance',not v_enabled,
      'one_round_test',v_one_round_test
    );
  end if;

  if r.status='FLYING' then
    result:=public.jl_aviator_tick(r.id);

    if result->>'status'='CRASHED' then
      perform public.jl_aviator_publish_proof(r.id);

      update public.jl_aviator_rounds
         set status='SETTLED',
             settled_at=now(),
             next_round_at=now()+interval '4 seconds'
       where id=r.id;

      if v_one_round_test then
        update public.jl_aviator_settings
           set enabled=false,
               one_round_test=false,
               updated_at=clock_timestamp()
         where id=true;

        insert into public.audit_log(action,details)
        values(
          'aviator.one_round_test_finished',
          jsonb_build_object('roundId',r.id,'finishedAt',clock_timestamp())
        );

        result:=result||jsonb_build_object(
          'auto_maintenance',true,
          'one_round_test',false
        );
      end if;
    end if;

    return result || jsonb_build_object(
      'maintenance',v_one_round_test or not v_enabled
    );
  end if;

  if r.status='CRASHED' then
    perform public.jl_aviator_publish_proof(r.id);

    update public.jl_aviator_rounds
       set status='SETTLED',
           settled_at=coalesce(settled_at,now()),
           next_round_at=coalesce(next_round_at,now()+interval '4 seconds')
     where id=r.id
     returning * into r;

    if v_one_round_test then
      update public.jl_aviator_settings
         set enabled=false,
             one_round_test=false,
             updated_at=clock_timestamp()
       where id=true;

      insert into public.audit_log(action,details)
      values(
        'aviator.one_round_test_finished',
        jsonb_build_object('roundId',r.id,'finishedAt',clock_timestamp())
      );
    end if;

    return jsonb_build_object(
      'action','RECOVERED_CRASHED',
      'round_id',r.id,
      'status',r.status,
      'maintenance',v_one_round_test or not v_enabled,
      'auto_maintenance',v_one_round_test,
      'one_round_test',false
    );
  end if;

  return jsonb_build_object(
    'action','WAIT',
    'round_id',r.id,
    'status',r.status,
    'maintenance',not v_enabled,
    'one_round_test',v_one_round_test
  );
end
$$;

revoke all on function public.jl_aviator_engine_tick()
from public,anon,authenticated;

grant execute on function public.jl_aviator_engine_tick()
to service_role;

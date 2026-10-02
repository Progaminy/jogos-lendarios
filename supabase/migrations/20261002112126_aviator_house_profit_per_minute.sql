-- Aviator: reserva automática de lucro da casa por minuto.
-- Regra padrão: 1,00 MT por minuto enquanto o Aviator estiver aberto.
-- O valor é ajustável pelo administrador.
-- O dinheiro é movido apenas da banca operacional para lucro reservado da casa;
-- nunca é debitado do saldo do jogador.
-- Durante LOCKED/FLYING a retirada espera a exposição terminar para não comprometer cash-outs.

alter table public.jl_aviator_settings
  add column if not exists house_profit_per_minute numeric(18,2)
  not null default 1.00
  check (house_profit_per_minute >= 0 and house_profit_per_minute <= 1000000);

alter table public.jl_aviator_bank
  add column if not exists house_profit_balance numeric(18,2)
  not null default 0
  check (house_profit_balance >= 0),
  add column if not exists house_profit_last_accrued_at timestamptz
  not null default clock_timestamp();

create or replace function public.jl_aviator_accrue_house_profit()
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_enabled boolean:=true;
  v_rate numeric:=1.00;
  v_last timestamptz;
  v_now timestamptz:=clock_timestamp();
  v_minutes bigint:=0;
  v_requested numeric:=0;
  v_moved numeric:=0;
  v_bank_after numeric:=0;
  v_profit_after numeric:=0;
  v_new_last timestamptz;
begin
  select
    coalesce(enabled,true),
    coalesce(house_profit_per_minute,1.00)
  into v_enabled,v_rate
  from public.jl_aviator_settings
  where id=true;

  if not coalesce(v_enabled,true) then
    return jsonb_build_object(
      'ok',true,
      'moved',0,
      'minutes',0,
      'rate_per_minute',v_rate,
      'maintenance',true
    );
  end if;

  -- Não reduzir a reserva enquanto uma rodada já tem risco financeiro travado.
  if exists(
    select 1
    from public.jl_aviator_rounds
    where status in ('LOCKED','FLYING')
    limit 1
  ) then
    return jsonb_build_object(
      'ok',true,
      'moved',0,
      'minutes',0,
      'rate_per_minute',v_rate,
      'deferred_for_exposure',true
    );
  end if;

  select house_profit_last_accrued_at
    into v_last
  from public.jl_aviator_bank
  where id=true;

  v_last:=coalesce(v_last,v_now);
  v_minutes:=floor(
    greatest(extract(epoch from (v_now-v_last)),0) / 60
  )::bigint;

  if v_minutes<=0 then
    return jsonb_build_object(
      'ok',true,
      'moved',0,
      'minutes',0,
      'rate_per_minute',v_rate
    );
  end if;

  perform pg_advisory_xact_lock(hashtext('jl_aviator_house_profit'));

  select
    house_profit_last_accrued_at,
    balance,
    house_profit_balance
  into v_last,v_bank_after,v_profit_after
  from public.jl_aviator_bank
  where id=true
  for update;

  v_last:=coalesce(v_last,v_now);
  v_minutes:=floor(
    greatest(extract(epoch from (v_now-v_last)),0) / 60
  )::bigint;

  if v_minutes<=0 then
    return jsonb_build_object(
      'ok',true,
      'moved',0,
      'minutes',0,
      'rate_per_minute',v_rate,
      'bank_balance',v_bank_after,
      'house_profit_balance',v_profit_after
    );
  end if;

  v_requested:=round(v_minutes*v_rate,2);
  v_moved:=round(least(v_requested,coalesce(v_bank_after,0)),2);
  v_new_last:=v_last+(v_minutes*interval '1 minute');

  update public.jl_aviator_bank
     set balance=round(balance-v_moved,2),
         house_profit_balance=round(house_profit_balance+v_moved,2),
         house_profit_last_accrued_at=v_new_last,
         updated_at=v_now
   where id=true
  returning balance,house_profit_balance
  into v_bank_after,v_profit_after;

  if v_moved>0 then
    insert into public.jl_aviator_bank_ledger(
      delta,
      balance_after,
      reason,
      request_key
    )
    values(
      -v_moved,
      v_bank_after,
      'Lucro reservado da casa: '||v_minutes||' minuto(s) × '||to_char(v_rate,'FM999999990.00')||' MT',
      'house-profit:'||extract(epoch from v_new_last)::bigint::text
    )
    on conflict do nothing;
  end if;

  return jsonb_build_object(
    'ok',true,
    'moved',v_moved,
    'minutes',v_minutes,
    'rate_per_minute',v_rate,
    'bank_balance',v_bank_after,
    'house_profit_balance',v_profit_after,
    'last_accrued_at',v_new_last
  );
end;
$function$;

revoke all on function public.jl_aviator_accrue_house_profit()
from public,anon,authenticated;
grant execute on function public.jl_aviator_accrue_house_profit()
to service_role;

create or replace function public.jl_aviator_admin_house_profit_state(
  p_token text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_admin uuid:=public.jl_admin_account_id(p_token);
  s public.jl_aviator_settings;
  b public.jl_aviator_bank;
begin
  if v_admin is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  select * into s
  from public.jl_aviator_settings
  where id=true;

  select * into b
  from public.jl_aviator_bank
  where id=true;

  return jsonb_build_object(
    'enabled',coalesce(s.enabled,true),
    'rate_per_minute',coalesce(s.house_profit_per_minute,1.00),
    'reserved_profit',coalesce(b.house_profit_balance,0),
    'bank_balance',coalesce(b.balance,0),
    'last_accrued_at',b.house_profit_last_accrued_at
  );
end;
$function$;

revoke all on function public.jl_aviator_admin_house_profit_state(text)
from public;
grant execute on function public.jl_aviator_admin_house_profit_state(text)
to anon,authenticated;

create or replace function public.jl_aviator_admin_set_house_profit_rate(
  p_token text,
  p_rate numeric
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_admin uuid:=public.jl_admin_account_id(p_token);
  v_previous numeric;
  v_current numeric;
  b public.jl_aviator_bank;
begin
  if v_admin is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  if p_rate is null
     or p_rate<0
     or p_rate>1000000
     or round(p_rate,2)<>p_rate then
    raise exception 'Valor por minuto inválido.';
  end if;

  -- Fecha o período anterior antes de trocar a tarifa.
  perform public.jl_aviator_accrue_house_profit();

  select house_profit_per_minute
    into v_previous
  from public.jl_aviator_settings
  where id=true
  for update;

  update public.jl_aviator_settings
     set house_profit_per_minute=round(p_rate,2),
         updated_at=clock_timestamp()
   where id=true
  returning house_profit_per_minute into v_current;

  -- A nova tarifa passa a contar a partir de agora, sem cobrança retroativa.
  update public.jl_aviator_bank
     set house_profit_last_accrued_at=clock_timestamp()
   where id=true
  returning * into b;

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
    'aviator.admin.house_profit_rate_changed',
    jsonb_build_object(
      'field','house_profit_per_minute',
      'previous',coalesce(v_previous,1.00),
      'current',v_current
    ),
    v_admin,
    nullif(current_setting('jl.admin_session_id',true),'')::uuid,
    nullif(current_setting('jl.admin_name',true),''),
    nullif(current_setting('jl.admin_role',true),''),
    'aviator_settings',
    'global',
    jsonb_build_object(
      'house_profit_per_minute',coalesce(v_previous,1.00)
    ),
    jsonb_build_object(
      'house_profit_per_minute',v_current
    )
  );

  return jsonb_build_object(
    'ok',true,
    'rate_per_minute',v_current,
    'reserved_profit',coalesce(b.house_profit_balance,0),
    'bank_balance',coalesce(b.balance,0),
    'last_accrued_at',b.house_profit_last_accrued_at
  );
end;
$function$;

revoke all on function public.jl_aviator_admin_set_house_profit_rate(text,numeric)
from public;
grant execute on function public.jl_aviator_admin_set_house_profit_rate(text,numeric)
to anon,authenticated;

-- Manutenção não gera cobrança retroativa. Ao fechar/reabrir, o relógio reinicia.
create or replace function public.jl_aviator_reset_house_profit_clock()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
begin
  if old.enabled is distinct from new.enabled then
    update public.jl_aviator_bank
       set house_profit_last_accrued_at=clock_timestamp()
     where id=true;
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_jl_aviator_reset_house_profit_clock
on public.jl_aviator_settings;

create trigger trg_jl_aviator_reset_house_profit_clock
after update of enabled
on public.jl_aviator_settings
for each row
execute function public.jl_aviator_reset_house_profit_clock();

revoke all on function public.jl_aviator_reset_house_profit_clock()
from public,anon,authenticated;
grant execute on function public.jl_aviator_reset_house_profit_clock()
to service_role;

-- Classificar corretamente a nova movimentação no histórico da banca.
create or replace function public.jl_aviator_admin_bank_ledger(
  p_token text,
  p_limit integer default 30
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_limit integer:=least(50,greatest(1,coalesce(p_limit,30)));
  v_rows jsonb;
begin
  perform public.jl_require_admin(p_token);

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',q.id,
        'type',q.entry_type,
        'delta',q.delta,
        'balance_after',q.balance_after,
        'reason',q.reason,
        'created_at',q.created_at
      )
      order by q.id desc
    ),
    '[]'::jsonb
  )
  into v_rows
  from (
    select
      l.id,
      case
        when l.request_key like 'cashout:%' then 'cashout'
        when l.request_key like 'lost-round:%' then 'lost_stake'
        when l.request_key like 'house-profit:%' then 'house_profit'
        else 'admin_adjustment'
      end as entry_type,
      l.delta,
      l.balance_after,
      l.reason,
      l.created_at
    from public.jl_aviator_bank_ledger l
    order by l.id desc
    limit v_limit
  ) q;

  return v_rows;
end;
$function$;

revoke all on function public.jl_aviator_admin_bank_ledger(text,integer)
from public;
grant execute on function public.jl_aviator_admin_bank_ledger(text,integer)
to anon,authenticated,service_role;

-- O cron já chama este tick a cada 2 segundos. A nova rotina só trava a banca
-- quando há pelo menos um minuto completo para reservar.
create or replace function public.jl_process_game_engine_tick()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_need_work boolean:=false;
  v_aviator_need boolean:=false;
  v_aviator_enabled boolean:=true;
  v_main jsonb;
  v_aviator jsonb;
  v_house_profit jsonb;
begin
  select exists(
    select 1
    from public.game_rounds
    where status in ('open','locked','closed')
      and ((status='open' and closes_at<=now()) or draw_at<=now())
  )
  or exists(
    select 1
    from public.draw_schedule ds
    join public.game_settings gs
      on gs.game_type=ds.game_type and gs.enabled
    where ds.status='pending'
      and not exists(
        select 1
        from public.game_rounds gr
        where gr.game_type=ds.game_type
          and gr.status in ('open','locked','closed','drawn')
      )
  )
  into v_need_work;

  select coalesce(enabled,true)
    into v_aviator_enabled
  from public.jl_aviator_settings
  where id=true;

  v_house_profit:=public.jl_aviator_accrue_house_profit();

  select
    exists(
      select 1
      from public.jl_aviator_rounds r
      where r.status in ('OPEN','LOCKED','FLYING','CRASHED')
        and (
          (not v_aviator_enabled and r.status in ('OPEN','LOCKED'))
          or r.status='CRASHED'
          or r.engine_due_at is null
          or r.engine_due_at<=clock_timestamp()
        )
    )
    or (
      v_aviator_enabled
      and (
        not exists(select 1 from public.jl_aviator_rounds)
        or exists(
          select 1
          from (
            select status,next_round_at
            from public.jl_aviator_rounds
            order by id desc
            limit 1
          ) latest
          where latest.status='CANCELLED'
             or (
               latest.status='SETTLED'
               and coalesce(latest.next_round_at,clock_timestamp())<=clock_timestamp()
             )
        )
      )
    )
  into v_aviator_need;

  if v_need_work then
    v_main:=public.jl_process_game_engine();
  else
    v_main:=jsonb_build_object('idle',true);
  end if;

  if v_aviator_need then
    v_aviator:=public.jl_aviator_engine_tick();
  else
    v_aviator:=jsonb_build_object(
      'idle',true,
      'maintenance',not v_aviator_enabled
    );
  end if;

  return jsonb_build_object(
    'main',v_main,
    'aviator',v_aviator,
    'house_profit',v_house_profit,
    'processed_at',now()
  );
end;
$function$;

revoke all on function public.jl_process_game_engine_tick()
from public,anon,authenticated;
grant execute on function public.jl_process_game_engine_tick()
to service_role;

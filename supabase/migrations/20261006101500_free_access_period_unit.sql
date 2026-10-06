-- Jogos Lendários: FREE billing period configurable by admin.
-- Supports per-day or per-month pricing while preserving the existing API.

alter table public.free_access_settings
  add column if not exists period_unit text not null default 'month',
  add column if not exists trial_limit integer not null default 10;

do $ begin
  alter table public.free_access_settings
    add constraint free_access_settings_trial_limit_ck
    check (trial_limit between 0 and 1000);
exception when duplicate_object then null; end $;

do $$ begin
  alter table public.free_access_settings
    add constraint free_access_settings_period_unit_ck
    check (period_unit in ('day','month'));
exception when duplicate_object then null; end $$;

alter table public.free_access_requests
  add column if not exists period_unit text not null default 'month';

do $$ begin
  alter table public.free_access_requests
    add constraint free_access_requests_period_unit_ck
    check (period_unit in ('day','month'));
exception when duplicate_object then null; end $$;

alter table public.free_access_memberships
  add column if not exists period_unit text not null default 'month';

do $$ begin
  alter table public.free_access_memberships
    add constraint free_access_memberships_period_unit_ck
    check (period_unit in ('day','month'));
exception when duplicate_object then null; end $$;

update public.free_access_requests r
set period_unit = coalesce(s.period_unit, 'month')
from public.free_access_settings s
where r.period_unit is null or r.period_unit = 'month';

create or replace function public.jl_free_access_status(p_token text)
returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','public'
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  s public.free_access_settings%rowtype;
  req public.free_access_requests%rowtype;
  mem public.free_access_memberships%rowtype;
  paid boolean:=false;
  games jsonb:='[]'::jsonb;
begin
  select * into s from public.free_access_settings where id=1;
  select * into mem from public.free_access_memberships where player_id=me;
  paid:=public.jl_free_access_active(me);

  select * into req
  from public.free_access_requests
  where player_id=me and status='pending'
  order by requested_at desc limit 1;

  select coalesce(
    jsonb_agg(public.jl_free_game_status(me,g.game_key) order by g.sort_order,g.game_key),
    '[]'::jsonb
  ) into games
  from public.free_game_catalog g;

  return jsonb_build_object(
    'enabled',coalesce(s.enabled,false),
    'price',coalesce(s.price,10),
    'price_period',coalesce(s.period_unit,'month'),
    'active',paid,
    'member_active',coalesce(mem.active,false),
    'valid_until',mem.valid_until,
    'status',case when req.id is not null then 'pending' when paid then 'active' else 'trial' end,
    'request_id',req.id,
    'pending_months',req.months,
    'pending_periods',req.months,
    'pending_period_unit',req.period_unit,
    'pending_amount',req.amount,
    'requested_at',req.requested_at,
    'balance',public.jl_player_ledger_balance(me),
    'games',games
  );
end;
$$;

create or replace function public.jl_free_access_request(p_token text,p_months integer)
returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','public','extensions'
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  s public.free_access_settings%rowtype;
  rid uuid:=extensions.gen_random_uuid();
  ledger_balance numeric;
  wallet_balance numeric;
  total numeric;
  period_label text;
begin
  if p_months is null or p_months not between 1 and 120 then
    raise exception 'Quantidade de períodos inválida.';
  end if;

  select * into s from public.free_access_settings where id=1 for update;
  if not coalesce(s.enabled,false) then
    raise exception 'FREE indisponível.';
  end if;

  if exists(
    select 1 from public.free_access_requests
    where player_id=me and status='pending'
  ) then
    return public.jl_free_access_status(p_token);
  end if;

  total:=round(s.price*p_months,2);
  if total>0 then
    perform public.jl_lock_player_wallet(me);
    ledger_balance:=public.jl_player_ledger_balance(me);
    select balance into wallet_balance from public.players where id=me for update;
    if coalesce(ledger_balance,0)<total or coalesce(wallet_balance,0)<total then
      raise exception 'Saldo insuficiente.';
    end if;
  end if;

  insert into public.free_access_requests(
    id,player_id,amount,status,months,unit_price,period_unit
  )
  values(rid,me,total,'pending',p_months,s.price,s.period_unit);

  if total>0 then
    update public.players
    set balance=round(balance-total,2),updated_at=now()
    where id=me;

    period_label:=p_months||
      case
        when s.period_unit='day' then case when p_months=1 then ' dia' else ' dias' end
        else case when p_months=1 then ' mês' else ' meses' end
      end;

    insert into public.transactions(player_id,kind,amount,status,reference_id,note)
    values(
      me,'free_access_payment',-total,'completed',rid,
      'FREE · '||period_label||' · pendente de aprovação'
    );
  end if;

  return public.jl_free_access_status(p_token);
end;
$$;

create or replace function public.jl_admin_free_access_settings(
  p_token text,
  p_price numeric,
  p_enabled boolean,
  p_period_unit text,
  p_trial_limit integer
)
returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','public'
as $$
begin
  perform public.jl_require_admin_elevated(p_token);
  if p_price is null or p_price < 0 or p_price > 1000000 then
    raise exception 'Valor inválido.';
  end if;
  if p_period_unit not in ('day','month') then
    raise exception 'Período inválido.';
  end if;
  if p_trial_limit is null or p_trial_limit not between 0 and 1000 then
    raise exception 'Quantidade de jogos FREE inválida.';
  end if;

  update public.free_access_settings
  set price=round(p_price,2),
      enabled=coalesce(p_enabled,true),
      period_unit=p_period_unit,
      trial_limit=p_trial_limit,
      updated_at=now()
  where id=1;

  return public.jl_admin_free_access_overview(p_token);
end;
$$;

create or replace function public.jl_admin_free_access_settings(
  p_token text,
  p_price numeric,
  p_enabled boolean
)
returns jsonb
language sql
security definer
set search_path='pg_catalog','public'
as $$
  select public.jl_admin_free_access_settings(p_token,p_price,p_enabled,'month',coalesce((select trial_limit from public.free_access_settings where id=1),10));
$$;

create or replace function public.jl_admin_free_access_overview(p_token text)
returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','public'
as $$
declare
  s public.free_access_settings%rowtype;
begin
  perform public.jl_require_admin_elevated(p_token);
  select * into s from public.free_access_settings where id=1;

  return jsonb_build_object(
    'settings',jsonb_build_object(
      'enabled',s.enabled,
      'price',s.price,
      'period_unit',s.period_unit,
      'trial_limit',s.trial_limit,
      'updated_at',s.updated_at
    ),
    'games',coalesce((
      select jsonb_agg(jsonb_build_object(
        'game_key',g.game_key,
        'label',g.label,
        'free_enabled',g.free_enabled,
        'bet_enabled',g.bet_enabled,
        'trial_limit',g.trial_limit
      ) order by g.sort_order,g.game_key)
      from public.free_game_catalog g
    ),'[]'::jsonb),
    'pending',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',r.id,
        'player_id',r.player_id,
        'name',p.name,
        'phone',p.phone,
        'amount',r.amount,
        'months',r.months,
        'periods',r.months,
        'unit_price',r.unit_price,
        'period_unit',r.period_unit,
        'status',r.status,
        'requested_at',r.requested_at
      ) order by r.requested_at)
      from public.free_access_requests r
      join public.players p on p.id=r.player_id
      where r.status='pending'
    ),'[]'::jsonb),
    'members',coalesce((
      select jsonb_agg(jsonb_build_object(
        'player_id',m.player_id,
        'name',p.name,
        'phone',p.phone,
        'active',m.active,
        'paid_active',public.jl_free_access_active(m.player_id),
        'amount_paid',m.amount_paid,
        'activated_at',m.activated_at,
        'valid_until',m.valid_until,
        'period_unit',m.period_unit
      ) order by m.updated_at desc)
      from public.free_access_memberships m
      join public.players p on p.id=m.player_id
    ),'[]'::jsonb)
  );
end;
$$;

create or replace function public.jl_admin_free_access_review(
  p_token text,
  p_request_id uuid,
  p_decision text
)
returns jsonb
language plpgsql
security definer
set search_path='pg_catalog','public'
as $$
declare
  req public.free_access_requests%rowtype;
  mem public.free_access_memberships%rowtype;
  admin_id uuid;
  base_until timestamptz;
  next_until timestamptz;
begin
  perform public.jl_require_admin_elevated(p_token);
  admin_id:=public.jl_admin_account_id(p_token);

  if p_decision not in ('approved','rejected') then
    raise exception 'Decisão inválida.';
  end if;

  select * into req
  from public.free_access_requests
  where id=p_request_id for update;

  if req.id is null or req.status<>'pending' then
    raise exception 'Pedido indisponível.';
  end if;

  update public.free_access_requests
  set status=p_decision,reviewed_at=now(),reviewed_by=admin_id
  where id=req.id;

  if p_decision='approved' then
    select * into mem
    from public.free_access_memberships
    where player_id=req.player_id for update;

    base_until:=greatest(coalesce(mem.valid_until,now()),now());

    if req.period_unit='day' then
      next_until:=base_until + make_interval(days=>coalesce(req.months,1));
    else
      next_until:=base_until + make_interval(months=>coalesce(req.months,1));
    end if;

    if mem.player_id is null then
      insert into public.free_access_memberships(
        player_id,active,amount_paid,request_id,activated_at,updated_at,
        valid_until,period_unit
      )
      values(
        req.player_id,true,req.amount,req.id,now(),now(),
        next_until,req.period_unit
      );
    else
      update public.free_access_memberships
      set active=true,
          amount_paid=round(amount_paid+req.amount,2),
          request_id=req.id,
          valid_until=next_until,
          period_unit=req.period_unit,
          updated_at=now()
      where player_id=req.player_id;
    end if;

  elsif req.amount>0 then
    perform public.jl_lock_player_wallet(req.player_id);

    update public.players
    set balance=round(balance+req.amount,2),updated_at=now()
    where id=req.player_id;

    insert into public.transactions(
      player_id,kind,amount,status,reference_id,note
    )
    values(
      req.player_id,'free_access_refund',req.amount,'completed',
      req.id,'FREE · pagamento devolvido'
    );

    update public.free_access_requests
    set refunded_at=now()
    where id=req.id;
  end if;

  return public.jl_admin_free_access_overview(p_token);
end;
$$;

revoke execute on function public.jl_admin_free_access_settings(text,numeric,boolean,text) from public;
revoke execute on function public.jl_admin_free_access_settings(text,numeric,boolean) from public;
grant execute on function public.jl_admin_free_access_settings(text,numeric,boolean,text) to anon,authenticated;
grant execute on function public.jl_admin_free_access_settings(text,numeric,boolean) to anon,authenticated;


revoke execute on function public.jl_admin_free_access_settings(text,numeric,boolean, text, integer) from public;
grant execute on function public.jl_admin_free_access_settings(text,numeric,boolean,text,integer) to anon,authenticated;

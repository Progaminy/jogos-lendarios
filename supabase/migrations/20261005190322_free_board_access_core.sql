create table if not exists public.free_access_settings (
  id smallint primary key check (id = 1),
  enabled boolean not null default true,
  price numeric(18,2) not null default 10 check (price >= 0),
  updated_at timestamptz not null default now()
);

insert into public.free_access_settings(id, enabled, price)
values (1, true, 10)
on conflict (id) do nothing;

create table if not exists public.free_access_requests (
  id uuid primary key default extensions.gen_random_uuid(),
  player_id uuid not null references public.players(id) on delete cascade,
  amount numeric(18,2) not null check (amount >= 0),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  requested_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid,
  refunded_at timestamptz
);

create unique index if not exists free_access_requests_one_pending
  on public.free_access_requests(player_id)
  where status = 'pending';

create table if not exists public.free_access_memberships (
  player_id uuid primary key references public.players(id) on delete cascade,
  active boolean not null default true,
  amount_paid numeric(18,2) not null default 0,
  request_id uuid references public.free_access_requests(id) on delete set null,
  activated_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.free_access_settings enable row level security;
alter table public.free_access_requests enable row level security;
alter table public.free_access_memberships enable row level security;
revoke all on public.free_access_settings from anon, authenticated;
revoke all on public.free_access_requests from anon, authenticated;
revoke all on public.free_access_memberships from anon, authenticated;

alter table public.ludo_rooms add column if not exists play_mode text not null default 'bet';
alter table public.dama_rooms add column if not exists play_mode text not null default 'bet';

do $$ begin
  alter table public.ludo_rooms add constraint ludo_rooms_play_mode_check check (play_mode in ('bet','free'));
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.dama_rooms add constraint dama_rooms_play_mode_check check (play_mode in ('bet','free'));
exception when duplicate_object then null; end $$;

create or replace function public.jl_free_access_active(p_player uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select m.active from public.free_access_memberships m where m.player_id = p_player), false);
$$;

create or replace function public.jl_free_access_require(p_player uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not coalesce((select s.enabled from public.free_access_settings s where s.id = 1), false) then
    raise exception 'FREE indisponível.';
  end if;
  if not public.jl_free_access_active(p_player) then raise exception 'FREE não ativo.'; end if;
end;
$$;

create or replace function public.jl_free_access_status(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := public.jl_player_id(p_token); s public.free_access_settings%rowtype; req public.free_access_requests%rowtype; member_active boolean;
begin
  select * into s from public.free_access_settings where id = 1;
  member_active := public.jl_free_access_active(me);
  select * into req from public.free_access_requests where player_id = me order by requested_at desc limit 1;
  return jsonb_build_object('enabled',coalesce(s.enabled,false),'price',coalesce(s.price,10),'member_active',member_active,
    'active',coalesce(s.enabled,false) and member_active,
    'status',case when coalesce(s.enabled,false) and member_active then 'active' else coalesce(req.status,'none') end,
    'request_id',req.id,'requested_at',req.requested_at,'balance',public.jl_player_ledger_balance(me));
end;
$$;

create or replace function public.jl_free_access_request(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid := public.jl_player_id(p_token); s public.free_access_settings%rowtype; rid uuid := extensions.gen_random_uuid(); ledger_balance numeric; wallet_balance numeric;
begin
  select * into s from public.free_access_settings where id = 1 for update;
  if not coalesce(s.enabled,false) then raise exception 'FREE indisponível.'; end if;
  if public.jl_free_access_active(me) then return public.jl_free_access_status(p_token); end if;
  if exists(select 1 from public.free_access_requests where player_id = me and status = 'pending') then return public.jl_free_access_status(p_token); end if;
  perform public.jl_lock_player_wallet(me);
  ledger_balance := public.jl_player_ledger_balance(me);
  select balance into wallet_balance from public.players where id = me for update;
  if coalesce(ledger_balance,0) < s.price or coalesce(wallet_balance,0) < s.price then raise exception 'Saldo insuficiente.'; end if;
  insert into public.free_access_requests(id,player_id,amount,status) values(rid,me,s.price,'pending');
  update public.players set balance=round(balance-s.price,2),updated_at=now() where id=me;
  insert into public.transactions(player_id,kind,amount,status,reference_id,note)
  values(me,'free_access_payment',-s.price,'completed',rid,'FREE · pagamento pendente de aprovação');
  return public.jl_free_access_status(p_token);
end;
$$;

create or replace function public.jl_admin_free_access_overview(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.free_access_settings%rowtype;
begin
  perform public.jl_require_admin_elevated(p_token);
  select * into s from public.free_access_settings where id = 1;
  return jsonb_build_object('settings',jsonb_build_object('enabled',s.enabled,'price',s.price,'updated_at',s.updated_at),
    'pending',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'player_id',r.player_id,'name',p.name,'phone',p.phone,'amount',r.amount,'status',r.status,'requested_at',r.requested_at) order by r.requested_at)
      from public.free_access_requests r join public.players p on p.id=r.player_id where r.status='pending'),'[]'::jsonb),
    'members',coalesce((select jsonb_agg(jsonb_build_object('player_id',m.player_id,'name',p.name,'phone',p.phone,'active',m.active,'amount_paid',m.amount_paid,'activated_at',m.activated_at) order by m.updated_at desc)
      from public.free_access_memberships m join public.players p on p.id=m.player_id),'[]'::jsonb));
end;
$$;

create or replace function public.jl_admin_free_access_settings(p_token text,p_price numeric,p_enabled boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform public.jl_require_admin_elevated(p_token);
  if p_price is null or p_price < 0 or p_price > 1000000 then raise exception 'Valor inválido.'; end if;
  update public.free_access_settings set price=round(p_price,2),enabled=coalesce(p_enabled,true),updated_at=now() where id=1;
  return public.jl_admin_free_access_overview(p_token);
end;
$$;

create or replace function public.jl_admin_free_access_review(p_token text,p_request_id uuid,p_decision text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare req public.free_access_requests%rowtype; admin_id uuid;
begin
  perform public.jl_require_admin_elevated(p_token);
  admin_id := public.jl_admin_account_id(p_token);
  if p_decision not in ('approved','rejected') then raise exception 'Decisão inválida.'; end if;
  select * into req from public.free_access_requests where id=p_request_id for update;
  if req.id is null or req.status<>'pending' then raise exception 'Pedido indisponível.'; end if;
  update public.free_access_requests set status=p_decision,reviewed_at=now(),reviewed_by=admin_id where id=req.id;
  if p_decision='approved' then
    insert into public.free_access_memberships(player_id,active,amount_paid,request_id,activated_at,updated_at)
    values(req.player_id,true,req.amount,req.id,now(),now())
    on conflict(player_id) do update set active=true,amount_paid=excluded.amount_paid,request_id=excluded.request_id,activated_at=now(),updated_at=now();
  else
    perform public.jl_lock_player_wallet(req.player_id);
    update public.players set balance=round(balance+req.amount,2),updated_at=now() where id=req.player_id;
    insert into public.transactions(player_id,kind,amount,status,reference_id,note)
    values(req.player_id,'free_access_refund',req.amount,'completed',req.id,'FREE · pagamento devolvido');
    update public.free_access_requests set refunded_at=now() where id=req.id;
  end if;
  return public.jl_admin_free_access_overview(p_token);
end;
$$;

create or replace function public.jl_admin_free_access_set_player(p_token text,p_player_id uuid,p_active boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform public.jl_require_admin_elevated(p_token);
  if not exists(select 1 from public.free_access_memberships where player_id=p_player_id) then raise exception 'FREE ainda não aprovado para este jogador.'; end if;
  update public.free_access_memberships set active=coalesce(p_active,false),updated_at=now() where player_id=p_player_id;
  return public.jl_admin_free_access_overview(p_token);
end;
$$;

create or replace function public.jl_free_room_player_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
declare pm text;
begin
  if tg_table_name='ludo_room_players' then select play_mode into pm from public.ludo_rooms where id=new.room_id;
  else select play_mode into pm from public.dama_rooms where id=new.room_id; end if;
  if pm='free' then perform public.jl_free_access_require(new.player_id); end if;
  return new;
end;
$$;

drop trigger if exists jl_free_guard_ludo_players on public.ludo_room_players;
create trigger jl_free_guard_ludo_players before insert or update of player_id,room_id on public.ludo_room_players for each row execute function public.jl_free_room_player_guard();
drop trigger if exists jl_free_guard_dama_players on public.dama_room_players;
create trigger jl_free_guard_dama_players before insert or update of player_id,room_id on public.dama_room_players for each row execute function public.jl_free_room_player_guard();

revoke execute on function public.jl_free_access_active(uuid) from public,anon,authenticated;
revoke execute on function public.jl_free_access_require(uuid) from public,anon,authenticated;
revoke execute on function public.jl_free_room_player_guard() from public,anon,authenticated;
revoke execute on function public.jl_free_access_status(text) from public;
revoke execute on function public.jl_free_access_request(text) from public;
revoke execute on function public.jl_admin_free_access_overview(text) from public;
revoke execute on function public.jl_admin_free_access_settings(text,numeric,boolean) from public;
revoke execute on function public.jl_admin_free_access_review(text,uuid,text) from public;
revoke execute on function public.jl_admin_free_access_set_player(text,uuid,boolean) from public;
grant execute on function public.jl_free_access_status(text) to anon,authenticated;
grant execute on function public.jl_free_access_request(text) to anon,authenticated;
grant execute on function public.jl_admin_free_access_overview(text) to anon,authenticated;
grant execute on function public.jl_admin_free_access_settings(text,numeric,boolean) to anon,authenticated;
grant execute on function public.jl_admin_free_access_review(text,uuid,text) to anon,authenticated;
grant execute on function public.jl_admin_free_access_set_player(text,uuid,boolean) to anon,authenticated;

create extension if not exists pgcrypto;

create table if not exists players (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  secret_hash text not null unique,
  balance numeric(14,2) not null default 0 check (balance >= 0),
  blocked boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists credit_requests (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references players(id) on delete cascade,
  amount numeric(14,2) not null check (amount > 0),
  note text not null default '' check (char_length(note) <= 160),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);

create table if not exists withdrawal_requests (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references players(id) on delete cascade,
  amount numeric(14,2) not null check (amount > 0),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);

create table if not exists bets (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references players(id) on delete cascade,
  selected_number integer not null check (selected_number between 0 and 10),
  drawn_number integer not null check (drawn_number between 0 and 10),
  amount numeric(14,2) not null check (amount > 0),
  won boolean not null,
  payout numeric(14,2) not null default 0 check (payout >= 0),
  created_at timestamptz not null default now()
);

create table if not exists audit_log (
  id uuid primary key default gen_random_uuid(),
  action text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_credit_requests_player on credit_requests(player_id, created_at desc);
create index if not exists idx_credit_requests_status on credit_requests(status, created_at desc);
create index if not exists idx_withdrawal_requests_player on withdrawal_requests(player_id, created_at desc);
create index if not exists idx_withdrawal_requests_status on withdrawal_requests(status, created_at desc);
create index if not exists idx_bets_player on bets(player_id, created_at desc);
create index if not exists idx_bets_created on bets(created_at desc);
create index if not exists idx_audit_created on audit_log(created_at desc);

alter table players enable row level security;
alter table credit_requests enable row level security;
alter table withdrawal_requests enable row level security;
alter table bets enable row level security;
alter table audit_log enable row level security;

-- Sem políticas públicas: o browser nunca fala diretamente com as tabelas.
-- As Cloudflare Functions usam a service role guardada como segredo do ambiente.

grant usage on schema public to service_role;
grant select, insert, update, delete on players, credit_requests, withdrawal_requests, bets, audit_log to service_role;

create or replace function jl_place_bet(
  p_player_id uuid,
  p_selected_number integer,
  p_amount numeric,
  p_drawn_number integer
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player players%rowtype;
  v_reserved numeric(14,2);
  v_won boolean;
  v_payout numeric(14,2);
  v_bet bets%rowtype;
begin
  if p_selected_number < 0 or p_selected_number > 10 or p_drawn_number < 0 or p_drawn_number > 10 then
    raise exception 'INVALID_NUMBER';
  end if;
  if p_amount is null or p_amount < 1 or p_amount > 1000000 then
    raise exception 'INVALID_AMOUNT';
  end if;

  select * into v_player from players where id = p_player_id for update;
  if not found then raise exception 'PLAYER_NOT_FOUND'; end if;
  if v_player.blocked then raise exception 'PLAYER_BLOCKED'; end if;

  select coalesce(sum(amount), 0) into v_reserved
  from withdrawal_requests
  where player_id = p_player_id and status = 'pending';

  if (v_player.balance - v_reserved) < p_amount then
    raise exception 'INSUFFICIENT_AVAILABLE_BALANCE';
  end if;

  v_won := p_selected_number = p_drawn_number;
  v_payout := case when v_won then round(p_amount * 10, 2) else 0 end;

  update players
  set balance = round(balance - p_amount + v_payout, 2)
  where id = p_player_id
  returning * into v_player;

  insert into bets(player_id, selected_number, drawn_number, amount, won, payout)
  values (p_player_id, p_selected_number, p_drawn_number, round(p_amount, 2), v_won, v_payout)
  returning * into v_bet;

  insert into audit_log(action, details)
  values ('bet.placed', jsonb_build_object(
    'betId', v_bet.id,
    'playerId', p_player_id,
    'amount', v_bet.amount,
    'selectedNumber', p_selected_number,
    'drawnNumber', p_drawn_number,
    'won', v_won,
    'payout', v_payout
  ));

  return jsonb_build_object(
    'id', v_bet.id,
    'playerId', v_bet.player_id,
    'selectedNumber', v_bet.selected_number,
    'drawnNumber', v_bet.drawn_number,
    'amount', v_bet.amount,
    'won', v_bet.won,
    'payout', v_bet.payout,
    'createdAt', v_bet.created_at,
    'balance', v_player.balance
  );
end;
$$;

create or replace function jl_request_withdrawal(
  p_player_id uuid,
  p_amount numeric
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player players%rowtype;
  v_reserved numeric(14,2);
  v_request withdrawal_requests%rowtype;
begin
  if p_amount is null or p_amount < 1 or p_amount > 1000000 then
    raise exception 'INVALID_AMOUNT';
  end if;

  select * into v_player from players where id = p_player_id for update;
  if not found then raise exception 'PLAYER_NOT_FOUND'; end if;
  if v_player.blocked then raise exception 'PLAYER_BLOCKED'; end if;

  select coalesce(sum(amount), 0) into v_reserved
  from withdrawal_requests
  where player_id = p_player_id and status = 'pending';

  if (v_player.balance - v_reserved) < p_amount then
    raise exception 'INSUFFICIENT_AVAILABLE_BALANCE';
  end if;

  insert into withdrawal_requests(player_id, amount)
  values (p_player_id, round(p_amount, 2))
  returning * into v_request;

  insert into audit_log(action, details)
  values ('withdrawal.requested', jsonb_build_object(
    'requestId', v_request.id,
    'playerId', p_player_id,
    'amount', v_request.amount
  ));

  return jsonb_build_object(
    'id', v_request.id,
    'playerId', v_request.player_id,
    'amount', v_request.amount,
    'status', v_request.status,
    'createdAt', v_request.created_at
  );
end;
$$;

create or replace function jl_review_withdrawal(
  p_request_id uuid,
  p_decision text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request withdrawal_requests%rowtype;
  v_player players%rowtype;
begin
  if p_decision not in ('approved','rejected') then
    raise exception 'INVALID_DECISION';
  end if;

  select * into v_request
  from withdrawal_requests
  where id = p_request_id
  for update;

  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if v_request.status <> 'pending' then raise exception 'REQUEST_ALREADY_REVIEWED'; end if;

  if p_decision = 'approved' then
    select * into v_player from players where id = v_request.player_id for update;
    if not found then raise exception 'PLAYER_NOT_FOUND'; end if;
    if v_player.balance < v_request.amount then raise exception 'INSUFFICIENT_BALANCE'; end if;

    update players
    set balance = round(balance - v_request.amount, 2)
    where id = v_request.player_id
    returning * into v_player;
  end if;

  update withdrawal_requests
  set status = p_decision, reviewed_at = now()
  where id = p_request_id
  returning * into v_request;

  insert into audit_log(action, details)
  values ('withdrawal.' || p_decision, jsonb_build_object(
    'requestId', v_request.id,
    'playerId', v_request.player_id,
    'amount', v_request.amount
  ));

  return jsonb_build_object(
    'id', v_request.id,
    'playerId', v_request.player_id,
    'amount', v_request.amount,
    'status', v_request.status,
    'reviewedAt', v_request.reviewed_at
  );
end;
$$;

create or replace function jl_review_credit(
  p_request_id uuid,
  p_decision text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request credit_requests%rowtype;
  v_player players%rowtype;
begin
  if p_decision not in ('approved','rejected') then
    raise exception 'INVALID_DECISION';
  end if;

  select * into v_request
  from credit_requests
  where id = p_request_id
  for update;

  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if v_request.status <> 'pending' then raise exception 'REQUEST_ALREADY_REVIEWED'; end if;

  if p_decision = 'approved' then
    update players
    set balance = round(balance + v_request.amount, 2)
    where id = v_request.player_id
    returning * into v_player;
    if not found then raise exception 'PLAYER_NOT_FOUND'; end if;
  end if;

  update credit_requests
  set status = p_decision, reviewed_at = now()
  where id = p_request_id
  returning * into v_request;

  insert into audit_log(action, details)
  values ('credit.' || p_decision, jsonb_build_object(
    'requestId', v_request.id,
    'playerId', v_request.player_id,
    'amount', v_request.amount
  ));

  return jsonb_build_object(
    'id', v_request.id,
    'playerId', v_request.player_id,
    'amount', v_request.amount,
    'status', v_request.status,
    'reviewedAt', v_request.reviewed_at
  );
end;
$$;

create or replace function jl_adjust_balance(
  p_player_id uuid,
  p_delta numeric
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player players%rowtype;
  v_reserved numeric(14,2);
begin
  if p_delta is null or p_delta = 0 or abs(p_delta) > 1000000 then
    raise exception 'INVALID_AMOUNT';
  end if;

  select * into v_player from players where id = p_player_id for update;
  if not found then raise exception 'PLAYER_NOT_FOUND'; end if;

  select coalesce(sum(amount), 0) into v_reserved
  from withdrawal_requests
  where player_id = p_player_id and status = 'pending';

  if (v_player.balance + p_delta) < v_reserved then
    raise exception 'RESERVED_BALANCE_CONFLICT';
  end if;

  update players
  set balance = round(balance + p_delta, 2)
  where id = p_player_id
  returning * into v_player;

  insert into audit_log(action, details)
  values ('player.balance_adjusted', jsonb_build_object(
    'playerId', p_player_id,
    'delta', p_delta,
    'balance', v_player.balance
  ));

  return jsonb_build_object('playerId', p_player_id, 'balance', v_player.balance);
end;
$$;

create or replace function jl_set_blocked(
  p_player_id uuid,
  p_blocked boolean
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player players%rowtype;
begin
  update players
  set blocked = p_blocked
  where id = p_player_id
  returning * into v_player;

  if not found then raise exception 'PLAYER_NOT_FOUND'; end if;

  insert into audit_log(action, details)
  values ('player.block_state_changed', jsonb_build_object(
    'playerId', p_player_id,
    'blocked', p_blocked
  ));

  return jsonb_build_object('playerId', p_player_id, 'blocked', v_player.blocked);
end;
$$;

revoke all on function jl_place_bet(uuid, integer, numeric, integer) from public, anon, authenticated;
revoke all on function jl_request_withdrawal(uuid, numeric) from public, anon, authenticated;
revoke all on function jl_review_withdrawal(uuid, text) from public, anon, authenticated;
revoke all on function jl_review_credit(uuid, text) from public, anon, authenticated;
revoke all on function jl_adjust_balance(uuid, numeric) from public, anon, authenticated;
revoke all on function jl_set_blocked(uuid, boolean) from public, anon, authenticated;

grant execute on function jl_place_bet(uuid, integer, numeric, integer) to service_role;
grant execute on function jl_request_withdrawal(uuid, numeric) to service_role;
grant execute on function jl_review_withdrawal(uuid, text) to service_role;
grant execute on function jl_review_credit(uuid, text) to service_role;
grant execute on function jl_adjust_balance(uuid, numeric) to service_role;
grant execute on function jl_set_blocked(uuid, boolean) to service_role;

create extension if not exists pgcrypto with schema extensions;

-- Keep admin_config (and its existing hash) but rebuild the application data model.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'jl_%'
  loop
    execute 'drop function if exists ' || r.signature || ' cascade';
  end loop;
end $$;

drop table if exists public.admin_sessions cascade;
drop table if exists public.player_sessions cascade;
drop table if exists public.audit_log cascade;
drop table if exists public.transactions cascade;
drop table if exists public.bets cascade;
drop table if exists public.credit_requests cascade;
drop table if exists public.deposit_requests cascade;
drop table if exists public.withdrawal_requests cascade;
drop table if exists public.game_rounds cascade;
drop table if exists public.messages cascade;
drop table if exists public.players cascade;

create table public.players (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 60),
  phone text not null unique,
  pin_hash text not null,
  balance numeric(14,2) not null default 0 check (balance >= 0),
  blocked boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.player_sessions (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.players(id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index player_sessions_player_idx on public.player_sessions(player_id);
create index player_sessions_expiry_idx on public.player_sessions(expires_at);

create table public.game_rounds (
  id uuid primary key default gen_random_uuid(),
  round_no bigint generated always as identity unique,
  status text not null default 'open' check (status in ('open','closed','drawn','published')),
  opened_at timestamptz not null default now(),
  closes_at timestamptz not null,
  closed_at timestamptz,
  drawn_number integer check (drawn_number between 0 and 10),
  drawn_at timestamptz,
  published_at timestamptz
);
create index game_rounds_status_idx on public.game_rounds(status, opened_at desc);

create table public.bets (
  id uuid primary key default gen_random_uuid(),
  round_id uuid not null references public.game_rounds(id) on delete restrict,
  player_id uuid not null references public.players(id) on delete restrict,
  selected_number integer not null check (selected_number between 0 and 10),
  amount numeric(14,2) not null check (amount > 0),
  won boolean,
  payout numeric(14,2) not null default 0 check (payout >= 0),
  created_at timestamptz not null default now()
);
create index bets_round_number_idx on public.bets(round_id, selected_number);
create index bets_player_idx on public.bets(player_id, created_at desc);

create table public.deposit_requests (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.players(id) on delete restrict,
  amount numeric(14,2) not null check (amount > 0),
  note text not null default '',
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
create index deposit_requests_status_idx on public.deposit_requests(status, created_at desc);

create table public.withdrawal_requests (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.players(id) on delete restrict,
  amount numeric(14,2) not null check (amount > 0),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reason text not null default '',
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
create index withdrawal_requests_status_idx on public.withdrawal_requests(status, created_at desc);

create table public.transactions (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.players(id) on delete restrict,
  kind text not null check (kind in ('deposit','withdrawal','withdrawal_refund','bet','payout','adjustment')),
  amount numeric(14,2) not null,
  status text not null default 'completed' check (status in ('pending','completed','rejected')),
  reference_id uuid,
  note text not null default '',
  created_at timestamptz not null default now()
);
create index transactions_player_idx on public.transactions(player_id, created_at desc);

create table public.admin_sessions (
  id uuid primary key default gen_random_uuid(),
  token_hash text not null unique,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index admin_sessions_expiry_idx on public.admin_sessions(expires_at);

-- RLS is enabled and there are intentionally no direct table policies.
-- The browser can only use the SECURITY DEFINER RPCs granted below.
alter table public.players enable row level security;
alter table public.player_sessions enable row level security;
alter table public.game_rounds enable row level security;
alter table public.bets enable row level security;
alter table public.deposit_requests enable row level security;
alter table public.withdrawal_requests enable row level security;
alter table public.transactions enable row level security;
alter table public.admin_sessions enable row level security;
alter table public.admin_config enable row level security;

revoke all on public.players, public.player_sessions, public.game_rounds, public.bets, public.deposit_requests, public.withdrawal_requests, public.transactions, public.admin_sessions, public.admin_config from anon, authenticated;

grant usage on schema public to anon, authenticated;

create or replace function public.jl_phone(p_phone text)
returns text
language sql immutable
set search_path = public
as $$
  select regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g');
$$;

create or replace function public.jl_token_hash(p_token text)
returns text
language sql immutable
set search_path = public, extensions
as $$
  select encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex');
$$;

create or replace function public.jl_player_id(p_token text)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_id uuid;
begin
  delete from public.player_sessions where expires_at <= now();
  select player_id into v_id
  from public.player_sessions
  where token_hash = public.jl_token_hash(p_token)
    and expires_at > now()
  limit 1;
  if v_id is null then
    raise exception 'Sessão do jogador inválida ou expirada.';
  end if;
  return v_id;
end;
$$;

create or replace function public.jl_admin_ok(p_token text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_ok boolean;
begin
  delete from public.admin_sessions where expires_at <= now();
  select exists(
    select 1 from public.admin_sessions
    where token_hash = public.jl_token_hash(p_token)
      and expires_at > now()
  ) into v_ok;
  return v_ok;
end;
$$;

create or replace function public.jl_require_admin(p_token text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.jl_admin_ok(p_token) then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;
end;
$$;

create or replace function public.jl_secure_number()
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $$
declare b integer;
begin
  loop
    b := get_byte(extensions.gen_random_bytes(1), 0);
    if b < 253 then
      return b % 11;
    end if;
  end loop;
end;
$$;

create or replace function public.jl_public_state()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_round public.game_rounds%rowtype;
declare v_last public.game_rounds%rowtype;
declare v_status text;
begin
  select * into v_round
  from public.game_rounds
  where status in ('open','closed','drawn')
  order by opened_at desc limit 1;

  if v_round.id is not null then
    v_status := case
      when v_round.status = 'open' and v_round.closes_at <= now() then 'closed'
      else v_round.status
    end;
  end if;

  select * into v_last
  from public.game_rounds
  where status = 'published'
  order by published_at desc nulls last, opened_at desc limit 1;

  return jsonb_build_object(
    'server_time', now(),
    'current_round', case when v_round.id is null then null else jsonb_build_object(
      'id', v_round.id,
      'round_no', v_round.round_no,
      'status', v_status,
      'opened_at', v_round.opened_at,
      'closes_at', v_round.closes_at
    ) end,
    'last_result', case when v_last.id is null then null else jsonb_build_object(
      'round_no', v_last.round_no,
      'drawn_number', v_last.drawn_number,
      'published_at', v_last.published_at
    ) end
  );
end;
$$;

create or replace function public.jl_register_player(p_name text, p_phone text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_phone text := public.jl_phone(p_phone);
declare v_player public.players%rowtype;
declare v_token text;
begin
  p_name := trim(coalesce(p_name,''));
  if char_length(p_name) < 2 or char_length(p_name) > 60 then
    raise exception 'Informe um nome entre 2 e 60 caracteres.';
  end if;
  if char_length(v_phone) < 8 or char_length(v_phone) > 15 then
    raise exception 'Número de telefone inválido.';
  end if;
  if coalesce(p_pin,'') !~ '^[0-9]{4,8}$' then
    raise exception 'O PIN deve ter de 4 a 8 dígitos.';
  end if;
  if exists(select 1 from public.players where phone = v_phone) then
    raise exception 'Este número de telefone já está cadastrado.';
  end if;

  insert into public.players(name, phone, pin_hash)
  values (p_name, v_phone, extensions.crypt(p_pin, extensions.gen_salt('bf', 10)))
  returning * into v_player;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.player_sessions(player_id, token_hash, expires_at)
  values (v_player.id, public.jl_token_hash(v_token), now() + interval '30 days');

  return jsonb_build_object(
    'token', v_token,
    'player', jsonb_build_object('id',v_player.id,'name',v_player.name,'phone',v_player.phone,'balance',v_player.balance,'blocked',v_player.blocked)
  );
end;
$$;

create or replace function public.jl_login_player(p_phone text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_phone text := public.jl_phone(p_phone);
declare v_player public.players%rowtype;
declare v_token text;
begin
  select * into v_player from public.players where phone = v_phone limit 1;
  if v_player.id is null or extensions.crypt(coalesce(p_pin,''), v_player.pin_hash) <> v_player.pin_hash then
    raise exception 'Telefone ou PIN incorreto.';
  end if;
  if v_player.blocked then
    raise exception 'Esta conta está bloqueada.';
  end if;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.player_sessions(player_id, token_hash, expires_at)
  values (v_player.id, public.jl_token_hash(v_token), now() + interval '30 days');

  return jsonb_build_object(
    'token', v_token,
    'player', jsonb_build_object('id',v_player.id,'name',v_player.name,'phone',v_player.phone,'balance',v_player.balance,'blocked',v_player.blocked)
  );
end;
$$;

create or replace function public.jl_logout_player(p_token text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.player_sessions where token_hash = public.jl_token_hash(p_token);
  return true;
end;
$$;

create or replace function public.jl_player_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_player_id uuid := public.jl_player_id(p_token);
declare v_player public.players%rowtype;
declare v_public jsonb;
declare v_bets jsonb;
declare v_deposits jsonb;
declare v_withdrawals jsonb;
begin
  select * into v_player from public.players where id = v_player_id;
  select public.jl_public_state() into v_public;

  select coalesce(jsonb_agg(x order by x.created_at desc), '[]'::jsonb) into v_bets
  from (
    select b.id,b.selected_number,b.amount,b.won,b.payout,b.created_at,r.round_no,
      case when r.status='published' then r.drawn_number else null end as drawn_number,
      r.status as round_status
    from public.bets b join public.game_rounds r on r.id=b.round_id
    where b.player_id=v_player_id
    order by b.created_at desc limit 30
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc), '[]'::jsonb) into v_deposits
  from (select id,amount,note,status,created_at,reviewed_at from public.deposit_requests where player_id=v_player_id order by created_at desc limit 20) x;

  select coalesce(jsonb_agg(x order by x.created_at desc), '[]'::jsonb) into v_withdrawals
  from (select id,amount,status,reason,created_at,reviewed_at from public.withdrawal_requests where player_id=v_player_id order by created_at desc limit 20) x;

  return v_public || jsonb_build_object(
    'player', jsonb_build_object('id',v_player.id,'name',v_player.name,'phone',v_player.phone,'balance',v_player.balance,'blocked',v_player.blocked),
    'bets', v_bets,
    'deposits', v_deposits,
    'withdrawals', v_withdrawals
  );
end;
$$;

create or replace function public.jl_place_bet(p_token text, p_selected_number integer, p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_player_id uuid := public.jl_player_id(p_token);
declare v_player public.players%rowtype;
declare v_round public.game_rounds%rowtype;
declare v_bet_id uuid;
begin
  if p_selected_number < 0 or p_selected_number > 10 then raise exception 'Escolha um número de 0 a 10.'; end if;
  if p_amount is null or p_amount < 1 or p_amount > 1000000 then raise exception 'Valor de aposta inválido.'; end if;

  select * into v_round from public.game_rounds
  where status='open' and closes_at > now()
  order by opened_at desc limit 1 for update;
  if v_round.id is null then raise exception 'As apostas estão fechadas neste momento.'; end if;

  select * into v_player from public.players where id=v_player_id for update;
  if v_player.blocked then raise exception 'Esta conta está bloqueada.'; end if;
  if v_player.balance < p_amount then raise exception 'Saldo insuficiente para esta aposta.'; end if;

  update public.players set balance=balance-p_amount, updated_at=now() where id=v_player_id;
  insert into public.bets(round_id,player_id,selected_number,amount)
  values(v_round.id,v_player_id,p_selected_number,round(p_amount,2)) returning id into v_bet_id;
  insert into public.transactions(player_id,kind,amount,status,reference_id,note)
  values(v_player_id,'bet',-round(p_amount,2),'completed',v_bet_id,'Aposta no Número Lendário');

  return jsonb_build_object('ok',true,'bet_id',v_bet_id,'round_no',v_round.round_no,'selected_number',p_selected_number,'amount',round(p_amount,2),'balance',v_player.balance-round(p_amount,2));
end;
$$;

create or replace function public.jl_request_deposit(p_token text, p_amount numeric, p_note text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_player_id uuid := public.jl_player_id(p_token);
declare v_id uuid;
begin
  if p_amount is null or p_amount < 1 or p_amount > 1000000 then raise exception 'Valor de depósito inválido.'; end if;
  insert into public.deposit_requests(player_id,amount,note)
  values(v_player_id,round(p_amount,2),left(trim(coalesce(p_note,'')),160)) returning id into v_id;
  return jsonb_build_object('ok',true,'request_id',v_id,'status','pending','message','Pedido de depósito enviado e aguardando confirmação do administrador.');
end;
$$;

create or replace function public.jl_request_withdrawal(p_token text, p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_player_id uuid := public.jl_player_id(p_token);
declare v_player public.players%rowtype;
declare v_id uuid;
begin
  if p_amount is null or p_amount < 1 or p_amount > 1000000 then raise exception 'Valor de saque inválido.'; end if;
  select * into v_player from public.players where id=v_player_id for update;

  if v_player.balance < p_amount then
    insert into public.withdrawal_requests(player_id,amount,status,reason,reviewed_at)
    values(v_player_id,round(p_amount,2),'rejected','Saldo insuficiente',now()) returning id into v_id;
    return jsonb_build_object('ok',false,'request_id',v_id,'status','rejected','message','Saque rejeitado automaticamente: saldo insuficiente.','balance',v_player.balance);
  end if;

  update public.players set balance=balance-round(p_amount,2), updated_at=now() where id=v_player_id;
  insert into public.withdrawal_requests(player_id,amount,status)
  values(v_player_id,round(p_amount,2),'pending') returning id into v_id;
  insert into public.transactions(player_id,kind,amount,status,reference_id,note)
  values(v_player_id,'withdrawal',-round(p_amount,2),'pending',v_id,'Valor reservado para saque');

  return jsonb_build_object('ok',true,'request_id',v_id,'status','pending','message','Pedido de saque enviado para autorização.','balance',v_player.balance-round(p_amount,2));
end;
$$;

create or replace function public.jl_admin_login(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_hash text;
declare v_token text;
begin
  select code_hash into v_hash from public.admin_config order by id limit 1;
  if v_hash is null or encode(extensions.digest(coalesce(p_code,''), 'sha256'),'hex') <> v_hash then
    raise exception 'Código administrativo incorreto.';
  end if;
  v_token := encode(extensions.gen_random_bytes(32),'hex');
  insert into public.admin_sessions(token_hash,expires_at)
  values(public.jl_token_hash(v_token),now()+interval '12 hours');
  return jsonb_build_object('token',v_token,'expires_in_hours',12);
end;
$$;

create or replace function public.jl_admin_logout(p_token text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.admin_sessions where token_hash=public.jl_token_hash(p_token);
  return true;
end;
$$;

create or replace function public.jl_admin_dashboard(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_round public.game_rounds%rowtype;
declare v_stats jsonb;
declare v_deposits jsonb;
declare v_withdrawals jsonb;
declare v_players jsonb;
declare v_recent_bets jsonb;
begin
  perform public.jl_require_admin(p_token);

  update public.game_rounds
  set status='closed', closed_at=coalesce(closed_at,closes_at)
  where status='open' and closes_at<=now();

  select * into v_round from public.game_rounds where status in ('open','closed','drawn') order by opened_at desc limit 1;

  select coalesce(jsonb_agg(jsonb_build_object('number',n,'bets',coalesce(s.bet_count,0),'total',coalesce(s.total,0)) order by n),'[]'::jsonb)
  into v_stats
  from generate_series(0,10) n
  left join (
    select selected_number,count(*)::int bet_count,sum(amount)::numeric total
    from public.bets where round_id=v_round.id group by selected_number
  ) s on s.selected_number=n;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_deposits
  from (select d.id,d.amount,d.note,d.status,d.created_at,p.name,p.phone from public.deposit_requests d join public.players p on p.id=d.player_id where d.status='pending' order by d.created_at desc limit 100) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_withdrawals
  from (select w.id,w.amount,w.status,w.reason,w.created_at,p.name,p.phone from public.withdrawal_requests w join public.players p on p.id=w.player_id where w.status='pending' order by w.created_at desc limit 100) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_players
  from (select id,name,phone,balance,blocked,created_at from public.players order by created_at desc limit 200) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_recent_bets
  from (select b.id,b.selected_number,b.amount,b.won,b.payout,b.created_at,p.name,p.phone,r.round_no from public.bets b join public.players p on p.id=b.player_id join public.game_rounds r on r.id=b.round_id order by b.created_at desc limit 100) x;

  return jsonb_build_object(
    'server_time',now(),
    'round',case when v_round.id is null then null else jsonb_build_object('id',v_round.id,'round_no',v_round.round_no,'status',v_round.status,'opened_at',v_round.opened_at,'closes_at',v_round.closes_at,'drawn_number',v_round.drawn_number,'drawn_at',v_round.drawn_at) end,
    'number_stats',v_stats,
    'pending_deposits',v_deposits,
    'pending_withdrawals',v_withdrawals,
    'players',v_players,
    'recent_bets',v_recent_bets
  );
end;
$$;

create or replace function public.jl_admin_open_round(p_token text, p_closes_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_round public.game_rounds%rowtype;
begin
  perform public.jl_require_admin(p_token);
  if p_closes_at is null or p_closes_at <= now()+interval '1 minute' or p_closes_at > now()+interval '7 days' then
    raise exception 'Defina o encerramento entre 1 minuto e 7 dias a partir de agora.';
  end if;
  if exists(select 1 from public.game_rounds where status in ('open','closed','drawn')) then
    raise exception 'Finalize e publique a rodada atual antes de abrir outra.';
  end if;
  insert into public.game_rounds(status,closes_at) values('open',p_closes_at) returning * into v_round;
  return jsonb_build_object('ok',true,'round_no',v_round.round_no,'closes_at',v_round.closes_at);
end;
$$;

create or replace function public.jl_admin_close_round(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_round public.game_rounds%rowtype;
begin
  perform public.jl_require_admin(p_token);
  select * into v_round from public.game_rounds where status='open' order by opened_at desc limit 1 for update;
  if v_round.id is null then raise exception 'Não há rodada aberta.'; end if;
  update public.game_rounds set status='closed',closed_at=now(),closes_at=least(closes_at,now()) where id=v_round.id returning * into v_round;
  return jsonb_build_object('ok',true,'round_no',v_round.round_no,'status',v_round.status);
end;
$$;

create or replace function public.jl_admin_draw_round(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_round public.game_rounds%rowtype;
declare v_number integer;
begin
  perform public.jl_require_admin(p_token);
  update public.game_rounds set status='closed',closed_at=coalesce(closed_at,closes_at) where status='open' and closes_at<=now();
  select * into v_round from public.game_rounds where status='closed' order by opened_at desc limit 1 for update;
  if v_round.id is null then raise exception 'Feche as apostas antes de sortear.'; end if;
  if v_round.drawn_number is not null then raise exception 'Esta rodada já foi sorteada e não pode ser sorteada novamente.'; end if;

  v_number := public.jl_secure_number();
  update public.game_rounds set status='drawn',drawn_number=v_number,drawn_at=now() where id=v_round.id;
  update public.bets set won=(selected_number=v_number), payout=case when selected_number=v_number then round(amount*10,2) else 0 end where round_id=v_round.id;

  update public.players p
  set balance=p.balance+w.total,updated_at=now()
  from (select player_id,sum(payout) total from public.bets where round_id=v_round.id and won=true group by player_id) w
  where p.id=w.player_id;

  insert into public.transactions(player_id,kind,amount,status,reference_id,note)
  select player_id,'payout',payout,'completed',id,'Prêmio da rodada '||v_round.round_no
  from public.bets where round_id=v_round.id and won=true and payout>0;

  return jsonb_build_object('ok',true,'round_no',v_round.round_no,'drawn_number',v_number,'message','Sorteio concluído. Publique o resultado quando estiver pronto.');
end;
$$;

create or replace function public.jl_admin_publish_round(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_round public.game_rounds%rowtype;
begin
  perform public.jl_require_admin(p_token);
  select * into v_round from public.game_rounds where status='drawn' order by opened_at desc limit 1 for update;
  if v_round.id is null then raise exception 'Faça o sorteio antes de publicar.'; end if;
  update public.game_rounds set status='published',published_at=now() where id=v_round.id returning * into v_round;
  return jsonb_build_object('ok',true,'round_no',v_round.round_no,'drawn_number',v_round.drawn_number,'published_at',v_round.published_at);
end;
$$;

create or replace function public.jl_admin_review_deposit(p_token text, p_request_id uuid, p_decision text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_req public.deposit_requests%rowtype;
begin
  perform public.jl_require_admin(p_token);
  if p_decision not in ('approved','rejected') then raise exception 'Decisão inválida.'; end if;
  select * into v_req from public.deposit_requests where id=p_request_id for update;
  if v_req.id is null or v_req.status<>'pending' then raise exception 'Pedido de depósito não está pendente.'; end if;
  update public.deposit_requests set status=p_decision,reviewed_at=now() where id=v_req.id;
  if p_decision='approved' then
    update public.players set balance=balance+v_req.amount,updated_at=now() where id=v_req.player_id;
    insert into public.transactions(player_id,kind,amount,status,reference_id,note) values(v_req.player_id,'deposit',v_req.amount,'completed',v_req.id,'Depósito aprovado');
  end if;
  return jsonb_build_object('ok',true,'status',p_decision,'request_id',v_req.id);
end;
$$;

create or replace function public.jl_admin_review_withdrawal(p_token text, p_request_id uuid, p_decision text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_req public.withdrawal_requests%rowtype;
begin
  perform public.jl_require_admin(p_token);
  if p_decision not in ('approved','rejected') then raise exception 'Decisão inválida.'; end if;
  select * into v_req from public.withdrawal_requests where id=p_request_id for update;
  if v_req.id is null or v_req.status<>'pending' then raise exception 'Pedido de saque não está pendente.'; end if;
  update public.withdrawal_requests set status=p_decision,reviewed_at=now(),reason=case when p_decision='rejected' then 'Rejeitado pelo administrador' else reason end where id=v_req.id;
  update public.transactions set status=case when p_decision='approved' then 'completed' else 'rejected' end where reference_id=v_req.id and kind='withdrawal' and status='pending';
  if p_decision='rejected' then
    update public.players set balance=balance+v_req.amount,updated_at=now() where id=v_req.player_id;
    insert into public.transactions(player_id,kind,amount,status,reference_id,note) values(v_req.player_id,'withdrawal_refund',v_req.amount,'completed',v_req.id,'Saque rejeitado: valor devolvido ao saldo');
  end if;
  return jsonb_build_object('ok',true,'status',p_decision,'request_id',v_req.id);
end;
$$;

create or replace function public.jl_admin_adjust_balance(p_token text, p_player_id uuid, p_delta numeric, p_note text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_balance numeric;
begin
  perform public.jl_require_admin(p_token);
  if p_delta is null or p_delta=0 or abs(p_delta)>1000000 then raise exception 'Ajuste inválido.'; end if;
  select balance into v_balance from public.players where id=p_player_id for update;
  if v_balance is null then raise exception 'Jogador não encontrado.'; end if;
  if v_balance+p_delta<0 then raise exception 'O ajuste deixaria o saldo negativo.'; end if;
  update public.players set balance=round(balance+p_delta,2),updated_at=now() where id=p_player_id returning balance into v_balance;
  insert into public.transactions(player_id,kind,amount,status,note) values(p_player_id,'adjustment',round(p_delta,2),'completed',left(trim(coalesce(p_note,'')),160));
  return jsonb_build_object('ok',true,'balance',v_balance);
end;
$$;

create or replace function public.jl_admin_set_blocked(p_token text, p_player_id uuid, p_blocked boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.jl_require_admin(p_token);
  update public.players set blocked=p_blocked,updated_at=now() where id=p_player_id;
  if not found then raise exception 'Jogador não encontrado.'; end if;
  return jsonb_build_object('ok',true,'blocked',p_blocked);
end;
$$;

-- Remove default PUBLIC execute privilege from internal and public RPCs, then grant only intended browser entrypoints.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as signature
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname like 'jl_%'
  loop
    execute 'revoke all on function ' || r.signature || ' from public';
  end loop;
end $$;

grant execute on function public.jl_public_state() to anon, authenticated;
grant execute on function public.jl_register_player(text,text,text) to anon, authenticated;
grant execute on function public.jl_login_player(text,text) to anon, authenticated;
grant execute on function public.jl_logout_player(text) to anon, authenticated;
grant execute on function public.jl_player_state(text) to anon, authenticated;
grant execute on function public.jl_place_bet(text,integer,numeric) to anon, authenticated;
grant execute on function public.jl_request_deposit(text,numeric,text) to anon, authenticated;
grant execute on function public.jl_request_withdrawal(text,numeric) to anon, authenticated;
grant execute on function public.jl_admin_login(text) to anon, authenticated;
grant execute on function public.jl_admin_logout(text) to anon, authenticated;
grant execute on function public.jl_admin_dashboard(text) to anon, authenticated;
grant execute on function public.jl_admin_open_round(text,timestamptz) to anon, authenticated;
grant execute on function public.jl_admin_close_round(text) to anon, authenticated;
grant execute on function public.jl_admin_draw_round(text) to anon, authenticated;
grant execute on function public.jl_admin_publish_round(text) to anon, authenticated;
grant execute on function public.jl_admin_review_deposit(text,uuid,text) to anon, authenticated;
grant execute on function public.jl_admin_review_withdrawal(text,uuid,text) to anon, authenticated;
grant execute on function public.jl_admin_adjust_balance(text,uuid,numeric,text) to anon, authenticated;
grant execute on function public.jl_admin_set_blocked(text,uuid,boolean) to anon, authenticated;

-- Initial round so the rebuilt site can be tested immediately.
insert into public.game_rounds(status,closes_at)
values('open', now()+interval '24 hours');

create table if not exists public.game_rounds (
  id uuid primary key default gen_random_uuid(),
  status text not null default 'open' check (status in ('open','closed','drawn','published')),
  opened_at timestamptz not null default now(),
  closes_at timestamptz,
  closed_at timestamptz,
  drawn_number integer check (drawn_number between 0 and 10),
  drawn_at timestamptz,
  published_at timestamptz
);

alter table public.game_rounds enable row level security;

alter table public.bets add column if not exists round_id uuid references public.game_rounds(id) on delete set null;
alter table public.bets alter column drawn_number drop not null;
alter table public.bets alter column won drop not null;
create index if not exists bets_round_id_idx on public.bets(round_id);
create index if not exists game_rounds_opened_at_idx on public.game_rounds(opened_at desc);

create or replace function public.jl_open_round(p_minutes integer default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round game_rounds%rowtype;
  v_closes timestamptz;
begin
  if exists(select 1 from game_rounds where status in ('open','closed','drawn')) then
    raise exception 'ROUND_ACTIVE';
  end if;
  if p_minutes is not null and (p_minutes < 1 or p_minutes > 1440) then
    raise exception 'INVALID_TIMER';
  end if;
  v_closes := case when p_minutes is null then null else now() + make_interval(mins => p_minutes) end;
  insert into game_rounds(status, closes_at)
  values ('open', v_closes)
  returning * into v_round;
  insert into audit_log(action, details)
  values ('round.opened', jsonb_build_object('roundId',v_round.id,'closesAt',v_round.closes_at));
  return jsonb_build_object('id',v_round.id,'status',v_round.status,'openedAt',v_round.opened_at,'closesAt',v_round.closes_at);
end;
$$;

create or replace function public.jl_close_round()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round game_rounds%rowtype;
begin
  select * into v_round from game_rounds where status='open' order by opened_at desc limit 1 for update;
  if not found then raise exception 'ROUND_NOT_OPEN'; end if;
  update game_rounds set status='closed', closed_at=now() where id=v_round.id returning * into v_round;
  insert into audit_log(action, details) values ('round.closed', jsonb_build_object('roundId',v_round.id));
  return jsonb_build_object('id',v_round.id,'status',v_round.status,'closedAt',v_round.closed_at);
end;
$$;

create or replace function public.jl_place_round_bet(p_player_id uuid, p_selected_number integer, p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round game_rounds%rowtype;
  v_player players%rowtype;
  v_reserved numeric(14,2);
  v_bet bets%rowtype;
begin
  if p_selected_number < 0 or p_selected_number > 10 then raise exception 'INVALID_NUMBER'; end if;
  if p_amount is null or p_amount < 1 or p_amount > 1000000 then raise exception 'INVALID_AMOUNT'; end if;

  select * into v_round from game_rounds where status='open' order by opened_at desc limit 1 for update;
  if not found then raise exception 'ROUND_NOT_OPEN'; end if;
  if v_round.closes_at is not null and now() >= v_round.closes_at then
    update game_rounds set status='closed', closed_at=coalesce(closed_at, now()) where id=v_round.id;
    raise exception 'ROUND_CLOSED';
  end if;

  select * into v_player from players where id=p_player_id for update;
  if not found then raise exception 'PLAYER_NOT_FOUND'; end if;
  if v_player.blocked then raise exception 'PLAYER_BLOCKED'; end if;

  select coalesce(sum(amount),0) into v_reserved from withdrawal_requests where player_id=p_player_id and status='pending';
  if (v_player.balance - v_reserved) < p_amount then raise exception 'INSUFFICIENT_AVAILABLE_BALANCE'; end if;

  update players set balance=round(balance-p_amount,2) where id=p_player_id returning * into v_player;
  insert into bets(player_id, round_id, selected_number, drawn_number, amount, won, payout)
  values (p_player_id, v_round.id, p_selected_number, null, round(p_amount,2), null, 0)
  returning * into v_bet;

  insert into audit_log(action, details)
  values ('round.bet_placed', jsonb_build_object('roundId',v_round.id,'betId',v_bet.id,'playerId',p_player_id,'selectedNumber',p_selected_number,'amount',v_bet.amount));

  return jsonb_build_object('id',v_bet.id,'roundId',v_round.id,'playerId',p_player_id,'selectedNumber',p_selected_number,'amount',v_bet.amount,'status','pending','createdAt',v_bet.created_at,'balance',v_player.balance);
end;
$$;

create or replace function public.jl_draw_round(p_drawn_number integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round game_rounds%rowtype;
begin
  if p_drawn_number < 0 or p_drawn_number > 10 then raise exception 'INVALID_NUMBER'; end if;
  select * into v_round from game_rounds where status in ('closed','drawn') order by opened_at desc limit 1 for update;
  if not found then raise exception 'ROUND_NOT_CLOSED'; end if;
  if v_round.status='drawn' or v_round.drawn_number is not null then raise exception 'RESULT_ALREADY_DRAWN'; end if;
  update game_rounds set status='drawn', drawn_number=p_drawn_number, drawn_at=now() where id=v_round.id returning * into v_round;
  insert into audit_log(action, details) values ('round.drawn',jsonb_build_object('roundId',v_round.id,'drawnNumber',p_drawn_number));
  return jsonb_build_object('id',v_round.id,'status',v_round.status,'drawnNumber',v_round.drawn_number,'drawnAt',v_round.drawn_at);
end;
$$;

create or replace function public.jl_publish_round()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round game_rounds%rowtype;
  v_winners jsonb;
begin
  select * into v_round from game_rounds where status='drawn' order by opened_at desc limit 1 for update;
  if not found then raise exception 'ROUND_NOT_DRAWN'; end if;

  update bets
  set drawn_number=v_round.drawn_number,
      won=(selected_number=v_round.drawn_number),
      payout=case when selected_number=v_round.drawn_number then round(amount*10,2) else 0 end
  where round_id=v_round.id;

  update players p
  set balance=round(p.balance+x.total_payout,2)
  from (
    select player_id, sum(payout) as total_payout
    from bets
    where round_id=v_round.id and won=true
    group by player_id
  ) x
  where p.id=x.player_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'playerId',b.player_id,
    'playerName',p.name,
    'selectedNumber',b.selected_number,
    'amount',b.amount,
    'payout',b.payout
  ) order by b.payout desc), '[]'::jsonb)
  into v_winners
  from bets b join players p on p.id=b.player_id
  where b.round_id=v_round.id and b.won=true;

  update game_rounds set status='published', published_at=now() where id=v_round.id returning * into v_round;
  insert into audit_log(action, details) values ('round.published',jsonb_build_object('roundId',v_round.id,'drawnNumber',v_round.drawn_number,'winners',v_winners));

  return jsonb_build_object('id',v_round.id,'status',v_round.status,'drawnNumber',v_round.drawn_number,'publishedAt',v_round.published_at,'winners',v_winners);
end;
$$;

create or replace function public.jl_place_bet(p_player_id uuid, p_selected_number integer, p_amount numeric, p_drawn_number integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  raise exception 'ROUND_ENGINE_REQUIRED';
end;
$$;

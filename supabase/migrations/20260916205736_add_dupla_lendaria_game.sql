alter table public.game_rounds
  add column if not exists pair_drawn_a integer,
  add column if not exists pair_drawn_b integer;

alter table public.game_rounds drop constraint if exists game_rounds_pair_drawn_a_check;
alter table public.game_rounds add constraint game_rounds_pair_drawn_a_check
  check (pair_drawn_a is null or pair_drawn_a between 1 and 10);

alter table public.game_rounds drop constraint if exists game_rounds_pair_drawn_b_check;
alter table public.game_rounds add constraint game_rounds_pair_drawn_b_check
  check (pair_drawn_b is null or pair_drawn_b between 1 and 10);

alter table public.game_rounds drop constraint if exists game_rounds_pair_distinct_check;
alter table public.game_rounds add constraint game_rounds_pair_distinct_check
  check (
    pair_drawn_a is null or pair_drawn_b is null or
    (pair_drawn_a < pair_drawn_b)
  );

create table if not exists public.pair_bets (
  id uuid primary key default gen_random_uuid(),
  round_id uuid not null references public.game_rounds(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  number_a integer not null check (number_a between 1 and 10),
  number_b integer not null check (number_b between 1 and 10),
  amount numeric not null check (amount > 0),
  won boolean,
  payout numeric not null default 0 check (payout >= 0),
  created_at timestamptz not null default now(),
  constraint pair_bets_canonical_pair_check check (number_a < number_b)
);

alter table public.pair_bets enable row level security;

create index if not exists pair_bets_round_idx on public.pair_bets(round_id);
create index if not exists pair_bets_player_created_idx on public.pair_bets(player_id, created_at desc);
create index if not exists pair_bets_round_pair_idx on public.pair_bets(round_id, number_a, number_b);

create or replace function public.jl_secure_pair(p_round_id uuid)
returns integer[]
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_byte integer;
  v_index integer;
  v_a integer;
  v_b integer;
begin
  if p_round_id is null or not exists (
    select 1 from public.game_rounds
    where id = p_round_id and status in ('open','locked','closed')
  ) then
    raise exception 'Nenhuma rodada válida para o sorteio da Dupla Lendária.';
  end if;

  -- Existem C(10,2) = 45 combinações sem ordem.
  -- 225 é o maior múltiplo de 45 abaixo de 256; rejeitar 225..255
  -- evita viés ao aplicar módulo 45.
  loop
    v_byte := get_byte(extensions.gen_random_bytes(1), 0);
    exit when v_byte < 225;
  end loop;

  v_index := (v_byte % 45) + 1;

  select a, b into v_a, v_b
  from (
    select a, b, row_number() over (order by a, b) as rn
    from generate_series(1, 10) a
    cross join generate_series(1, 10) b
    where a < b
  ) combos
  where rn = v_index;

  return array[v_a, v_b];
end;
$$;

create or replace function public.jl_place_pair_bet(
  p_token text,
  p_number_a integer,
  p_number_b integer,
  p_amount numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := public.jl_player_id(p_token);
  v_player public.players%rowtype;
  v_round public.game_rounds%rowtype;
  v_bet_id uuid;
  v_a integer;
  v_b integer;
begin
  if p_number_a is null or p_number_b is null then
    raise exception 'Escolha dois números.';
  end if;

  if p_number_a < 1 or p_number_a > 10 or p_number_b < 1 or p_number_b > 10 then
    raise exception 'Escolha dois números entre 1 e 10.';
  end if;

  if p_number_a = p_number_b then
    raise exception 'Escolha dois números diferentes.';
  end if;

  v_a := least(p_number_a, p_number_b);
  v_b := greatest(p_number_a, p_number_b);

  if p_amount is null or p_amount < 10 or p_amount > 500 then
    raise exception 'A aposta deve ser entre 10 e 500 MZN.';
  end if;

  select * into v_round
  from public.game_rounds
  where status = 'open' and closes_at > now()
  order by opened_at desc
  limit 1
  for update;

  if v_round.id is null then
    raise exception 'As apostas estão fechadas neste momento.';
  end if;

  select * into v_player
  from public.players
  where id = v_player_id
  for update;

  if v_player.blocked then
    raise exception 'Esta conta está bloqueada.';
  end if;

  if v_player.balance < p_amount then
    raise exception 'Saldo insuficiente para esta aposta.';
  end if;

  update public.players
  set balance = balance - p_amount,
      updated_at = now()
  where id = v_player_id;

  insert into public.pair_bets(round_id, player_id, number_a, number_b, amount)
  values(v_round.id, v_player_id, v_a, v_b, round(p_amount, 2))
  returning id into v_bet_id;

  insert into public.transactions(player_id, kind, amount, status, reference_id, note)
  values(v_player_id, 'bet', -round(p_amount, 2), 'completed', v_bet_id,
         'Aposta Dupla Lendária ' || v_a || '+' || v_b);

  return jsonb_build_object(
    'ok', true,
    'bet_id', v_bet_id,
    'round_no', v_round.round_no,
    'number_a', v_a,
    'number_b', v_b,
    'amount', round(p_amount, 2),
    'balance', v_player.balance - round(p_amount, 2)
  );
end;
$$;

create or replace function public.jl_finalize_due_rounds()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round public.game_rounds%rowtype;
  v_number integer;
  v_pair integer[];
  v_count integer := 0;
begin
  for v_round in
    select *
    from public.game_rounds
    where status in ('open','locked','closed')
      and drawn_number is null
      and draw_at <= now()
    order by draw_at, opened_at
    for update skip locked
  loop
    v_number := public.jl_secure_number();
    v_pair := public.jl_secure_pair(v_round.id);

    update public.game_rounds
    set status = 'published',
        closed_at = coalesce(closed_at, closes_at),
        drawn_number = v_number,
        pair_drawn_a = v_pair[1],
        pair_drawn_b = v_pair[2],
        drawn_at = now(),
        published_at = now()
    where id = v_round.id;

    update public.bets
    set won = (selected_number = v_number),
        payout = case when selected_number = v_number then round(amount * 10, 2) else 0 end
    where round_id = v_round.id;

    update public.pair_bets
    set won = (number_a = v_pair[1] and number_b = v_pair[2]),
        payout = case
          when number_a = v_pair[1] and number_b = v_pair[2] then round(amount * 50, 2)
          else 0
        end
    where round_id = v_round.id;

    update public.players p
    set balance = p.balance + w.total,
        updated_at = now()
    from (
      select player_id, sum(payout) as total
      from (
        select player_id, payout from public.bets
        where round_id = v_round.id and won = true and payout > 0
        union all
        select player_id, payout from public.pair_bets
        where round_id = v_round.id and won = true and payout > 0
      ) prizes
      group by player_id
    ) w
    where p.id = w.player_id;

    insert into public.transactions(player_id, kind, amount, status, reference_id, note)
    select player_id, 'payout', payout, 'completed', id,
           'Prêmio Número Lendário da rodada ' || v_round.round_no
    from public.bets
    where round_id = v_round.id and won = true and payout > 0;

    insert into public.transactions(player_id, kind, amount, status, reference_id, note)
    select player_id, 'payout', payout, 'completed', id,
           'Prêmio Dupla Lendária ' || v_pair[1] || '+' || v_pair[2] || ' da rodada ' || v_round.round_no
    from public.pair_bets
    where round_id = v_round.id and won = true and payout > 0;

    if v_round.schedule_id is not null then
      update public.draw_schedule
      set status = 'completed', updated_at = now()
      where id = v_round.schedule_id;
    end if;

    insert into public.audit_log(action, details)
    values ('round.auto_draw_published', jsonb_build_object(
      'round_id', v_round.id,
      'round_no', v_round.round_no,
      'drawn_number', v_number,
      'pair_drawn_a', v_pair[1],
      'pair_drawn_b', v_pair[2],
      'bet_lock_at', v_round.closes_at,
      'scheduled_draw_at', v_round.draw_at,
      'processed_at', now()
    ));

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

create or replace function public.jl_public_state()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round public.game_rounds%rowtype;
  v_last public.game_rounds%rowtype;
begin
  perform public.jl_process_game_engine();

  select * into v_round
  from public.game_rounds
  where status in ('open','locked','closed')
  order by opened_at desc limit 1;

  select * into v_last
  from public.game_rounds
  where status='published'
  order by published_at desc nulls last, opened_at desc limit 1;

  return jsonb_build_object(
    'server_time', now(),
    'current_round', case when v_round.id is null then null else jsonb_build_object(
      'id',v_round.id,'round_no',v_round.round_no,'status',v_round.status,
      'opened_at',v_round.opened_at,'closes_at',v_round.closes_at,'draw_at',v_round.draw_at
    ) end,
    'last_result', case when v_last.id is null then null else jsonb_build_object(
      'round_no',v_last.round_no,
      'drawn_number',v_last.drawn_number,
      'pair_drawn_a',v_last.pair_drawn_a,
      'pair_drawn_b',v_last.pair_drawn_b,
      'drawn_at',v_last.drawn_at,
      'published_at',v_last.published_at
    ) end
  );
end;
$$;

create or replace function public.jl_player_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := public.jl_player_id(p_token);
  v_player public.players%rowtype;
  v_public jsonb;
  v_bets jsonb;
  v_pair_bets jsonb;
  v_deposits jsonb;
  v_withdrawals jsonb;
begin
  select * into v_player from public.players where id = v_player_id;
  select public.jl_public_state() into v_public;

  select coalesce(jsonb_agg(x order by x.created_at desc), '[]'::jsonb) into v_bets
  from (
    select b.id,b.selected_number,b.amount,b.won,b.payout,b.created_at,r.round_no,
      case when r.status='published' then r.drawn_number else null end as drawn_number,
      r.status as round_status
    from public.bets b
    join public.game_rounds r on r.id=b.round_id
    where b.player_id=v_player_id
    order by b.created_at desc limit 30
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc), '[]'::jsonb) into v_pair_bets
  from (
    select pb.id,pb.number_a,pb.number_b,pb.amount,pb.won,pb.payout,pb.created_at,r.round_no,
      case when r.status='published' then r.pair_drawn_a else null end as pair_drawn_a,
      case when r.status='published' then r.pair_drawn_b else null end as pair_drawn_b,
      r.status as round_status
    from public.pair_bets pb
    join public.game_rounds r on r.id=pb.round_id
    where pb.player_id=v_player_id
    order by pb.created_at desc limit 30
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc), '[]'::jsonb) into v_deposits
  from (
    select id,amount,note,status,created_at,reviewed_at
    from public.deposit_requests
    where player_id=v_player_id
    order by created_at desc limit 20
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc), '[]'::jsonb) into v_withdrawals
  from (
    select id,amount,status,reason,created_at,reviewed_at
    from public.withdrawal_requests
    where player_id=v_player_id
    order by created_at desc limit 20
  ) x;

  return v_public || jsonb_build_object(
    'player', jsonb_build_object(
      'id',v_player.id,'name',v_player.name,'phone',v_player.phone,
      'balance',v_player.balance,'blocked',v_player.blocked
    ),
    'bets', v_bets,
    'pair_bets', v_pair_bets,
    'deposits', v_deposits,
    'withdrawals', v_withdrawals
  );
end;
$$;

create or replace function public.jl_admin_dashboard(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round public.game_rounds%rowtype;
  v_last public.game_rounds%rowtype;
  v_stats jsonb;
  v_pair_stats jsonb;
  v_deposits jsonb;
  v_withdrawals jsonb;
  v_players jsonb;
  v_recent_bets jsonb;
  v_recent_pair_bets jsonb;
  v_schedule jsonb;
begin
  perform public.jl_require_admin(p_token);
  perform public.jl_process_game_engine();

  select * into v_round
  from public.game_rounds
  where status in ('open','locked','closed')
  order by opened_at desc limit 1;

  select * into v_last
  from public.game_rounds
  where status='published'
  order by published_at desc nulls last, opened_at desc limit 1;

  select coalesce(jsonb_agg(jsonb_build_object(
    'number',n,'bets',coalesce(s.bet_count,0),'total',coalesce(s.total,0)
  ) order by n),'[]'::jsonb)
  into v_stats
  from generate_series(0,10) n
  left join (
    select selected_number,count(*)::int bet_count,sum(amount)::numeric total
    from public.bets where round_id=v_round.id group by selected_number
  ) s on s.selected_number=n;

  select coalesce(jsonb_agg(jsonb_build_object(
    'number_a',c.a,'number_b',c.b,
    'bets',coalesce(s.bet_count,0),'total',coalesce(s.total,0)
  ) order by c.a,c.b),'[]'::jsonb)
  into v_pair_stats
  from (
    select a,b
    from generate_series(1,10) a
    cross join generate_series(1,10) b
    where a < b
  ) c
  left join (
    select number_a,number_b,count(*)::int bet_count,sum(amount)::numeric total
    from public.pair_bets where round_id=v_round.id
    group by number_a,number_b
  ) s on s.number_a=c.a and s.number_b=c.b;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_deposits
  from (select d.id,d.amount,d.note,d.status,d.created_at,p.name,p.phone from public.deposit_requests d join public.players p on p.id=d.player_id where d.status='pending' order by d.created_at desc limit 100) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_withdrawals
  from (select w.id,w.amount,w.status,w.reason,w.created_at,p.name,p.phone from public.withdrawal_requests w join public.players p on p.id=w.player_id where w.status='pending' order by w.created_at desc limit 100) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_players
  from (select id,name,phone,balance,blocked,created_at from public.players order by created_at desc limit 200) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_recent_bets
  from (select b.id,b.selected_number,b.amount,b.won,b.payout,b.created_at,p.name,p.phone,r.round_no from public.bets b join public.players p on p.id=b.player_id join public.game_rounds r on r.id=b.round_id order by b.created_at desc limit 100) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_recent_pair_bets
  from (select pb.id,pb.number_a,pb.number_b,pb.amount,pb.won,pb.payout,pb.created_at,p.name,p.phone,r.round_no from public.pair_bets pb join public.players p on p.id=pb.player_id join public.game_rounds r on r.id=pb.round_id order by pb.created_at desc limit 100) x;

  select coalesce(jsonb_agg(x order by x.draw_at),'[]'::jsonb) into v_schedule
  from (select id,draw_at,status,round_id,created_at from public.draw_schedule where status in ('pending','active') order by draw_at limit 250) x;

  return jsonb_build_object(
    'server_time',now(),
    'lock_seconds',3,
    'round',case when v_round.id is null then null else jsonb_build_object(
      'id',v_round.id,'round_no',v_round.round_no,'status',v_round.status,
      'opened_at',v_round.opened_at,'closes_at',v_round.closes_at,
      'draw_at',v_round.draw_at,'schedule_id',v_round.schedule_id
    ) end,
    'last_result',case when v_last.id is null then null else jsonb_build_object(
      'round_no',v_last.round_no,'drawn_number',v_last.drawn_number,
      'pair_drawn_a',v_last.pair_drawn_a,'pair_drawn_b',v_last.pair_drawn_b,
      'drawn_at',v_last.drawn_at,'published_at',v_last.published_at
    ) end,
    'number_stats',v_stats,
    'pair_stats',v_pair_stats,
    'draw_schedule',v_schedule,
    'pending_deposits',v_deposits,
    'pending_withdrawals',v_withdrawals,
    'players',v_players,
    'recent_bets',v_recent_bets,
    'recent_pair_bets',v_recent_pair_bets
  );
end;
$$;

revoke execute on function public.jl_secure_pair(uuid) from public;

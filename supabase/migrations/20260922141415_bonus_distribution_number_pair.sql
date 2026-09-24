create table if not exists public.bonus_grants (
  id uuid primary key default extensions.gen_random_uuid(),
  player_id uuid not null references public.players(id) on delete cascade,
  game_scope text not null check (game_scope in ('number','pair','both')),
  bonus_type text not null check (bonus_type in ('promotional','welcome','loyalty','compensation','manual')),
  original_amount numeric not null check (original_amount > 0 and original_amount = trunc(original_amount)),
  remaining_amount numeric not null check (remaining_amount >= 0 and remaining_amount = trunc(remaining_amount)),
  played_amount numeric not null default 0 check (played_amount >= 0 and played_amount = trunc(played_amount)),
  status text not null default 'active' check (status in ('active','consumed','cancelled')),
  note text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.bonus_grants enable row level security;

create index if not exists bonus_grants_player_active_idx
on public.bonus_grants(player_id, game_scope, created_at)
where status='active' and remaining_amount>0;

create table if not exists public.bonus_usages (
  id uuid primary key default extensions.gen_random_uuid(),
  grant_id uuid not null references public.bonus_grants(id) on delete restrict,
  player_id uuid not null references public.players(id) on delete restrict,
  game_type text not null check (game_type in ('number','pair')),
  bet_id uuid not null,
  amount numeric not null check (amount > 0 and amount = trunc(amount)),
  created_at timestamptz not null default now()
);

alter table public.bonus_usages enable row level security;

alter table public.bets
  add column if not exists cash_amount numeric not null default 0,
  add column if not exists bonus_amount numeric not null default 0;

alter table public.pair_bets
  add column if not exists cash_amount numeric not null default 0,
  add column if not exists bonus_amount numeric not null default 0;

update public.bets
set cash_amount=amount, bonus_amount=0
where cash_amount=0 and bonus_amount=0 and amount>0;

update public.pair_bets
set cash_amount=amount, bonus_amount=0
where cash_amount=0 and bonus_amount=0 and amount>0;

alter table public.bets drop constraint if exists bets_funding_source_check;
alter table public.bets add constraint bets_funding_source_check
check (cash_amount>=0 and bonus_amount>=0 and cash_amount+bonus_amount=amount);

alter table public.pair_bets drop constraint if exists pair_bets_funding_source_check;
alter table public.pair_bets add constraint pair_bets_funding_source_check
check (cash_amount>=0 and bonus_amount>=0 and cash_amount+bonus_amount=amount);

create or replace function public.jl_bonus_available(p_player_id uuid,p_game_type text)
returns numeric
language sql
security definer
set search_path=public
as $$
  select coalesce(sum(remaining_amount),0)
  from public.bonus_grants
  where player_id=p_player_id
    and status='active'
    and remaining_amount>0
    and (game_scope=p_game_type or game_scope='both');
$$;

revoke all on function public.jl_bonus_available(uuid,text) from public,anon,authenticated;

create or replace function public.jl_consume_bonus(
  p_player_id uuid,
  p_game_type text,
  p_amount numeric,
  p_bet_id uuid
)
returns numeric
language plpgsql
security definer
set search_path=public
as $$
declare
  g public.bonus_grants%rowtype;
  need numeric:=greatest(0,coalesce(p_amount,0));
  take numeric;
  used numeric:=0;
begin
  if p_game_type not in ('number','pair') then raise exception 'Jogo de bónus inválido.'; end if;
  if need<=0 then return 0; end if;

  for g in
    select *
    from public.bonus_grants
    where player_id=p_player_id
      and status='active'
      and remaining_amount>0
      and (game_scope=p_game_type or game_scope='both')
    order by created_at,id
    for update
  loop
    exit when need<=0;
    take:=least(need,g.remaining_amount);

    update public.bonus_grants
    set remaining_amount=remaining_amount-take,
        played_amount=played_amount+take,
        status=case when remaining_amount-take<=0 then 'consumed' else 'active' end,
        updated_at=now()
    where id=g.id;

    insert into public.bonus_usages(grant_id,player_id,game_type,bet_id,amount)
    values(g.id,p_player_id,p_game_type,p_bet_id,take);

    used:=used+take;
    need:=need-take;
  end loop;

  return used;
end;
$$;

revoke all on function public.jl_consume_bonus(uuid,text,numeric,uuid) from public,anon,authenticated;

create or replace function public.jl_admin_grant_bonus(
  p_token text,
  p_player_ids uuid[],
  p_game_scope text,
  p_bonus_type text,
  p_amount numeric,
  p_note text default ''
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  granted_count int:=0;
  total_amount numeric:=0;
begin
  perform public.jl_require_admin(p_token);

  if p_game_scope not in ('number','pair','both') then raise exception 'Jogo do bónus inválido.'; end if;
  if p_bonus_type not in ('promotional','welcome','loyalty','compensation','manual') then raise exception 'Tipo de bónus inválido.'; end if;
  if p_amount is null or p_amount<1 or p_amount>1000000 or p_amount<>trunc(p_amount) then
    raise exception 'O bónus deve ser um valor inteiro entre 1 e 1.000.000 MZN.';
  end if;
  if p_player_ids is null or coalesce(array_length(p_player_ids,1),0)=0 then raise exception 'Selecione pelo menos um jogador.'; end if;
  if array_length(p_player_ids,1)>200 then raise exception 'Selecione no máximo 200 jogadores por distribuição.'; end if;

  insert into public.bonus_grants(player_id,game_scope,bonus_type,original_amount,remaining_amount,note)
  select distinct p.id,p_game_scope,p_bonus_type,p_amount,p_amount,left(trim(coalesce(p_note,'')),160)
  from public.players p
  where p.id=any(p_player_ids)
  on conflict do nothing;

  get diagnostics granted_count=row_count;
  total_amount:=granted_count*p_amount;

  if granted_count=0 then raise exception 'Nenhum jogador válido selecionado.'; end if;

  insert into public.audit_log(action,details)
  values('bonus.distributed',jsonb_build_object(
    'game_scope',p_game_scope,
    'bonus_type',p_bonus_type,
    'amount_each',p_amount,
    'players',granted_count,
    'total_amount',total_amount,
    'note',left(trim(coalesce(p_note,'')),160),
    'created_at',now()
  ));

  return jsonb_build_object(
    'ok',true,
    'players',granted_count,
    'amount_each',p_amount,
    'total_amount',total_amount,
    'game_scope',p_game_scope,
    'bonus_type',p_bonus_type
  );
end;
$$;

create or replace function public.jl_admin_bonus_overview(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare player_rows jsonb; grant_rows jsonb;
begin
  perform public.jl_require_admin(p_token);

  select coalesce(jsonb_agg(x order by x.name,x.phone),'[]'::jsonb)
  into player_rows
  from (
    select p.id,p.name,p.phone,p.balance,
      coalesce(sum(g.remaining_amount) filter(where g.status='active'),0) bonus_total,
      coalesce(sum(g.remaining_amount) filter(where g.status='active' and g.game_scope in ('number','both')),0) number_bonus,
      coalesce(sum(g.remaining_amount) filter(where g.status='active' and g.game_scope in ('pair','both')),0) pair_bonus
    from public.players p
    left join public.bonus_grants g on g.player_id=p.id
    group by p.id,p.name,p.phone,p.balance
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb)
  into grant_rows
  from (
    select g.id,g.player_id,p.name,p.phone,g.game_scope,g.bonus_type,
      g.original_amount,g.remaining_amount,g.played_amount,g.status,g.note,g.created_at
    from public.bonus_grants g
    join public.players p on p.id=g.player_id
    order by g.created_at desc
    limit 150
  ) x;

  return jsonb_build_object('players',player_rows,'recent_grants',grant_rows);
end;
$$;

create or replace function public.jl_place_bet(p_token text,p_selected_number integer,p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_player public.players%rowtype;
  v_round public.game_rounds%rowtype;
  v_settings public.game_settings%rowtype;
  v_bet_id uuid;
  v_total_after numeric;
  v_min_after numeric;
  v_bonus_available numeric:=0;
  v_bonus_used numeric:=0;
  v_cash_used numeric:=0;
  v_consumed numeric:=0;
begin
  select * into v_settings from public.game_settings where game_type='number';
  if not v_settings.enabled then raise exception 'Número Lendário está temporariamente desativado.'; end if;
  if p_selected_number<0 or p_selected_number>10 then raise exception 'Escolha um número de 0 a 10.'; end if;
  if p_amount is null or p_amount<>trunc(p_amount) or p_amount<v_settings.min_bet or p_amount>v_settings.max_bet then
    raise exception 'A aposta deve ser um valor inteiro entre % e % MZN.',v_settings.min_bet,v_settings.max_bet;
  end if;

  select * into v_round from public.game_rounds
  where game_type='number' and status='open' and closes_at>now()
  order by opened_at desc limit 1 for update;
  if v_round.id is null then raise exception 'As apostas do Número Lendário estão fechadas neste momento.'; end if;

  select * into v_player from public.players where id=v_player_id for update;
  if v_player.blocked then raise exception 'Esta conta está bloqueada.'; end if;

  v_bonus_available:=public.jl_bonus_available(v_player_id,'number');
  if v_player.balance+v_bonus_available<p_amount then
    raise exception 'Saldo e bónus insuficientes para esta aposta.';
  end if;

  v_bonus_used:=least(p_amount,v_bonus_available);
  v_cash_used:=p_amount-v_bonus_used;

  select coalesce(sum(amount),0)+p_amount into v_total_after from public.bets where round_id=v_round.id;
  select min(exposure) into v_min_after
  from (
    select n,coalesce(sum(b.amount),0)+case when n=p_selected_number then p_amount else 0 end exposure
    from generate_series(0,10) n
    left join public.bets b on b.round_id=v_round.id and b.selected_number=n
    group by n
  ) x;

  if v_min_after*v_settings.multiplier>=v_total_after then
    raise exception 'Esta aposta atingiria o limite de segurança da rodada. Escolha outro número ou aguarde a próxima rodada.';
  end if;

  insert into public.bets(round_id,player_id,selected_number,amount,cash_amount,bonus_amount)
  values(v_round.id,v_player_id,p_selected_number,p_amount,v_cash_used,v_bonus_used)
  returning id into v_bet_id;

  if v_bonus_used>0 then
    v_consumed:=public.jl_consume_bonus(v_player_id,'number',v_bonus_used,v_bet_id);
    if v_consumed<>v_bonus_used then raise exception 'Não foi possível reservar o bónus desta aposta.'; end if;
  end if;

  if v_cash_used>0 then
    update public.players set balance=balance-v_cash_used,updated_at=now() where id=v_player_id;
    insert into public.transactions(player_id,kind,amount,status,reference_id,note)
    values(v_player_id,'bet',-v_cash_used,'completed',v_bet_id,
      'Aposta no Número Lendário · '||v_bonus_used||' MZN de bónus');
  end if;

  return jsonb_build_object(
    'ok',true,'bet_id',v_bet_id,'round_no',v_round.round_no,
    'selected_number',p_selected_number,'amount',p_amount,
    'cash_used',v_cash_used,'bonus_used',v_bonus_used,
    'balance',v_player.balance-v_cash_used,
    'bonus_remaining',public.jl_bonus_available(v_player_id,'number')
  );
end;
$$;

create or replace function public.jl_place_pair_bet(p_token text,p_number_a integer,p_number_b integer,p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_player public.players%rowtype;
  v_round public.game_rounds%rowtype;
  v_settings public.game_settings%rowtype;
  v_bet_id uuid;
  v_a integer;
  v_b integer;
  v_total_after numeric;
  v_min_after numeric;
  v_bonus_available numeric:=0;
  v_bonus_used numeric:=0;
  v_cash_used numeric:=0;
  v_consumed numeric:=0;
begin
  select * into v_settings from public.game_settings where game_type='pair';
  if not v_settings.enabled then raise exception 'Dupla Lendária está temporariamente desativada.'; end if;
  if p_number_a is null or p_number_b is null then raise exception 'Escolha dois números.'; end if;
  if p_number_a<0 or p_number_a>10 or p_number_b<0 or p_number_b>10 then raise exception 'Escolha dois números entre 0 e 10.'; end if;
  if p_number_a=p_number_b then raise exception 'Escolha dois números diferentes.'; end if;

  v_a:=least(p_number_a,p_number_b);
  v_b:=greatest(p_number_a,p_number_b);

  if p_amount is null or p_amount<>trunc(p_amount) or p_amount<v_settings.min_bet or p_amount>v_settings.max_bet then
    raise exception 'A aposta deve ser um valor inteiro entre % e % MZN.',v_settings.min_bet,v_settings.max_bet;
  end if;

  select * into v_round from public.game_rounds
  where game_type='pair' and status='open' and closes_at>now()
  order by opened_at desc limit 1 for update;
  if v_round.id is null then raise exception 'As apostas da Dupla Lendária estão fechadas neste momento.'; end if;

  select * into v_player from public.players where id=v_player_id for update;
  if v_player.blocked then raise exception 'Esta conta está bloqueada.'; end if;

  v_bonus_available:=public.jl_bonus_available(v_player_id,'pair');
  if v_player.balance+v_bonus_available<p_amount then
    raise exception 'Saldo e bónus insuficientes para esta aposta.';
  end if;

  v_bonus_used:=least(p_amount,v_bonus_available);
  v_cash_used:=p_amount-v_bonus_used;

  select coalesce(sum(amount),0)+p_amount into v_total_after from public.pair_bets where round_id=v_round.id;
  select min(exposure) into v_min_after
  from (
    select a,b,coalesce(sum(pb.amount),0)+case when a=v_a and b=v_b then p_amount else 0 end exposure
    from generate_series(0,10) a
    cross join generate_series(0,10) b
    left join public.pair_bets pb on pb.round_id=v_round.id and pb.number_a=a and pb.number_b=b
    where a<b
    group by a,b
  ) x;

  if v_min_after*v_settings.multiplier>=v_total_after then
    raise exception 'Esta aposta atingiria o limite de segurança da rodada. Escolha outra combinação ou aguarde a próxima rodada.';
  end if;

  insert into public.pair_bets(round_id,player_id,number_a,number_b,amount,cash_amount,bonus_amount)
  values(v_round.id,v_player_id,v_a,v_b,p_amount,v_cash_used,v_bonus_used)
  returning id into v_bet_id;

  if v_bonus_used>0 then
    v_consumed:=public.jl_consume_bonus(v_player_id,'pair',v_bonus_used,v_bet_id);
    if v_consumed<>v_bonus_used then raise exception 'Não foi possível reservar o bónus desta aposta.'; end if;
  end if;

  if v_cash_used>0 then
    update public.players set balance=balance-v_cash_used,updated_at=now() where id=v_player_id;
    insert into public.transactions(player_id,kind,amount,status,reference_id,note)
    values(v_player_id,'bet',-v_cash_used,'completed',v_bet_id,
      'Aposta Dupla Lendária '||v_a||'+'||v_b||' · '||v_bonus_used||' MZN de bónus');
  end if;

  return jsonb_build_object(
    'ok',true,'bet_id',v_bet_id,'round_no',v_round.round_no,
    'number_a',v_a,'number_b',v_b,'amount',p_amount,
    'cash_used',v_cash_used,'bonus_used',v_bonus_used,
    'balance',v_player.balance-v_cash_used,
    'bonus_remaining',public.jl_bonus_available(v_player_id,'pair')
  );
end;
$$;

create or replace function public.jl_player_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_player public.players%rowtype;
  v_public jsonb;
  v_bets jsonb;
  v_pair_bets jsonb;
  v_deposits jsonb;
  v_withdrawals jsonb;
  v_bonus_total numeric;
  v_bonus_number numeric;
  v_bonus_pair numeric;
  v_bonus_grants jsonb;
begin
  select * into v_player from public.players where id=v_player_id;
  select public.jl_public_state() into v_public;

  select
    coalesce(sum(remaining_amount) filter(where status='active'),0),
    coalesce(sum(remaining_amount) filter(where status='active' and game_scope in ('number','both')),0),
    coalesce(sum(remaining_amount) filter(where status='active' and game_scope in ('pair','both')),0)
  into v_bonus_total,v_bonus_number,v_bonus_pair
  from public.bonus_grants where player_id=v_player_id;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_bonus_grants
  from (
    select id,game_scope,bonus_type,original_amount,remaining_amount,played_amount,status,note,created_at
    from public.bonus_grants
    where player_id=v_player_id
    order by created_at desc
    limit 30
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_bets
  from (
    select b.id,b.selected_number,b.amount,b.cash_amount,b.bonus_amount,b.won,b.payout,b.created_at,r.round_no,
      case when r.status='published' then r.drawn_number else null end drawn_number,r.status round_status
    from public.bets b join public.game_rounds r on r.id=b.round_id
    where b.player_id=v_player_id order by b.created_at desc limit 30
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_pair_bets
  from (
    select pb.id,pb.number_a,pb.number_b,pb.amount,pb.cash_amount,pb.bonus_amount,pb.won,pb.payout,pb.created_at,r.round_no,
      case when r.status='published' then r.pair_drawn_a else null end pair_drawn_a,
      case when r.status='published' then r.pair_drawn_b else null end pair_drawn_b,
      r.status round_status
    from public.pair_bets pb join public.game_rounds r on r.id=pb.round_id
    where pb.player_id=v_player_id order by pb.created_at desc limit 30
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_deposits
  from (select id,amount,note,status,created_at,reviewed_at from public.deposit_requests where player_id=v_player_id order by created_at desc limit 20) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_withdrawals
  from (select id,amount,status,reason,created_at,reviewed_at from public.withdrawal_requests where player_id=v_player_id order by created_at desc limit 20) x;

  return v_public || jsonb_build_object(
    'player',jsonb_build_object(
      'id',v_player.id,'name',v_player.name,'phone',v_player.phone,
      'balance',v_player.balance,'bonus_balance',v_bonus_total,'blocked',v_player.blocked
    ),
    'bonus',jsonb_build_object(
      'total',v_bonus_total,'number',v_bonus_number,'pair',v_bonus_pair,'grants',v_bonus_grants
    ),
    'bets',v_bets,'pair_bets',v_pair_bets,'deposits',v_deposits,'withdrawals',v_withdrawals
  );
end;
$$;

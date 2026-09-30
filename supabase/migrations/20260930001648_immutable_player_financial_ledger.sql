
-- Ledger financeiro canónico, append-only, separado do saldo-cache exibido.
-- A tabela transactions continua a representar o evento/origem de negócio.
-- player_financial_ledger passa a ser a fonte contabilística imutável.

create table if not exists public.player_financial_ledger (
  id bigint generated always as identity primary key,
  transaction_id uuid not null unique
    references public.transactions(id) on delete restrict,
  player_id uuid not null
    references public.players(id) on delete restrict,
  delta numeric(18,2) not null check(delta<>0),
  balance_after numeric(18,2) not null check(balance_after>=0),
  kind text not null,
  status_at_posting text not null,
  reference_id uuid,
  note text not null default '',
  occurred_at timestamptz not null,
  recorded_at timestamptz not null default clock_timestamp()
);

create index if not exists player_financial_ledger_player_id_idx
on public.player_financial_ledger(player_id,id desc);

create index if not exists player_financial_ledger_player_occurred_idx
on public.player_financial_ledger(player_id,occurred_at desc,id desc);

alter table public.player_financial_ledger enable row level security;
revoke all on table public.player_financial_ledger
from public,anon,authenticated;
grant select,insert on table public.player_financial_ledger to service_role;

-- Backfill integral do histórico. Cada linha de transactions representa um
-- movimento de saldo; inclusive um saque depois rejeitado preserva o débito
-- original e o respectivo withdrawal_refund como dois eventos distintos.
insert into public.player_financial_ledger(
  transaction_id,
  player_id,
  delta,
  balance_after,
  kind,
  status_at_posting,
  reference_id,
  note,
  occurred_at,
  recorded_at
)
select
  t.id,
  t.player_id,
  round(t.amount,2),
  round(
    sum(t.amount) over(
      partition by t.player_id
      order by t.created_at,t.id
      rows between unbounded preceding and current row
    ),
    2
  ),
  t.kind,
  t.status,
  t.reference_id,
  t.note,
  t.created_at,
  t.created_at
from public.transactions t
where not exists(
  select 1
  from public.player_financial_ledger l
  where l.transaction_id=t.id
)
order by t.player_id,t.created_at,t.id;

-- Aborta a migration se o histórico não reconstruir exatamente o saldo-cache.
do $$
begin
  if exists(
    select 1
    from public.players p
    left join lateral(
      select l.balance_after
      from public.player_financial_ledger l
      where l.player_id=p.id
      order by l.id desc
      limit 1
    ) x on true
    where round(p.balance,2)<>round(coalesce(x.balance_after,0),2)
  ) then
    raise exception
      'Reconciliação inicial falhou: saldo-cache diverge do ledger.';
  end if;
end
$$;

create or replace function public.jl_reject_player_ledger_mutation()
returns trigger
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
begin
  raise exception 'Ledger financeiro é imutável: UPDATE/DELETE não permitido.';
end
$$;

drop trigger if exists jl_player_financial_ledger_immutable
on public.player_financial_ledger;

create trigger jl_player_financial_ledger_immutable
before update or delete on public.player_financial_ledger
for each row
execute function public.jl_reject_player_ledger_mutation();

create or replace function public.jl_append_player_financial_ledger()
returns trigger
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  v_before numeric:=0;
  v_after numeric;
begin
  perform pg_advisory_xact_lock(
    hashtextextended('jl_player_financial_ledger:'||new.player_id::text,0)
  );

  if exists(
    select 1
    from public.player_financial_ledger
    where transaction_id=new.id
  ) then
    return new;
  end if;

  select l.balance_after
    into v_before
  from public.player_financial_ledger l
  where l.player_id=new.player_id
  order by l.id desc
  limit 1;

  v_before:=coalesce(v_before,0);
  v_after:=round(v_before+new.amount,2);

  if v_after<0 then
    raise exception
      'Movimento financeiro deixaria o ledger negativo.';
  end if;

  insert into public.player_financial_ledger(
    transaction_id,
    player_id,
    delta,
    balance_after,
    kind,
    status_at_posting,
    reference_id,
    note,
    occurred_at
  )
  values(
    new.id,
    new.player_id,
    round(new.amount,2),
    v_after,
    new.kind,
    new.status,
    new.reference_id,
    new.note,
    new.created_at
  );

  return new;
end
$$;

drop trigger if exists jl_transactions_append_financial_ledger
on public.transactions;

create trigger jl_transactions_append_financial_ledger
after insert on public.transactions
for each row
execute function public.jl_append_player_financial_ledger();

-- O movimento financeiro de uma transaction nunca pode ser reescrito.
-- Status e note podem mudar para concluir fluxos como saque pendente,
-- sem alterar o lançamento contabilístico original.
create or replace function public.jl_reject_transaction_financial_mutation()
returns trigger
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
begin
  if new.id is distinct from old.id
     or new.player_id is distinct from old.player_id
     or new.kind is distinct from old.kind
     or new.amount is distinct from old.amount
     or new.reference_id is distinct from old.reference_id
     or new.created_at is distinct from old.created_at
     or new.aviator_bet_id is distinct from old.aviator_bet_id
     or new.aviator_operation is distinct from old.aviator_operation then
    raise exception
      'Movimento financeiro confirmado é imutável.';
  end if;

  return new;
end
$$;

drop trigger if exists jl_transactions_financial_fields_immutable
on public.transactions;

create trigger jl_transactions_financial_fields_immutable
before update on public.transactions
for each row
execute function public.jl_reject_transaction_financial_mutation();

-- A FK do ledger já impede DELETE de transactions que possuem lançamento.

create or replace function public.jl_player_ledger_balance(
  p_player_id uuid
)
returns numeric
language sql
security definer
stable
set search_path=pg_catalog,public
as $$
  select coalesce(
    (
      select l.balance_after
      from public.player_financial_ledger l
      where l.player_id=p_player_id
      order by l.id desc
      limit 1
    ),
    0
  )::numeric(18,2);
$$;

-- Invariante bidireccional:
-- 1) mudar players.balance exige lançamento correspondente;
-- 2) criar lançamento exige que o saldo-cache termine igual ao ledger.
create or replace function public.jl_assert_player_balance_reconciled()
returns trigger
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  v_player_id uuid;
  v_cache numeric;
  v_ledger numeric;
begin
  if tg_table_name='players' then
    if old.balance is not distinct from new.balance then
      return new;
    end if;
    v_player_id:=new.id;
  else
    v_player_id:=new.player_id;
  end if;

  select p.balance
    into v_cache
  from public.players p
  where p.id=v_player_id;

  if v_cache is null then
    raise exception 'Jogador financeiro não encontrado.';
  end if;

  v_ledger:=public.jl_player_ledger_balance(v_player_id);

  if round(v_cache,2)<>round(v_ledger,2) then
    raise exception
      'Saldo-cache divergente do ledger financeiro para jogador %: cache %, ledger %.',
      v_player_id,round(v_cache,2),round(v_ledger,2);
  end if;

  return new;
end
$$;

drop trigger if exists jl_players_balance_reconcile
on public.players;

create constraint trigger jl_players_balance_reconcile
after update on public.players
deferrable initially deferred
for each row
execute function public.jl_assert_player_balance_reconciled();

drop trigger if exists jl_transactions_balance_reconcile
on public.transactions;

create constraint trigger jl_transactions_balance_reconcile
after insert on public.transactions
deferrable initially deferred
for each row
execute function public.jl_assert_player_balance_reconciled();

revoke all on function public.jl_reject_player_ledger_mutation()
from public,anon,authenticated;
revoke all on function public.jl_append_player_financial_ledger()
from public,anon,authenticated;
revoke all on function public.jl_reject_transaction_financial_mutation()
from public,anon,authenticated;
revoke all on function public.jl_assert_player_balance_reconciled()
from public,anon,authenticated;
revoke all on function public.jl_player_ledger_balance(uuid)
from public,anon,authenticated;
grant execute on function public.jl_player_ledger_balance(uuid)
to service_role;

-- O estado privado do Aviator lê o saldo contabilístico, não o cache.
create or replace function public.jl_aviator_player_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  v_player uuid:=public.jl_player_id(p_token);
  v_balance numeric;
  v_bets jsonb;
begin
  v_balance:=public.jl_player_ledger_balance(v_player);

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',q.id,
        'round_id',q.round_id,
        'stake',q.stake,
        'status',q.status,
        'auto_cashout_multiplier',q.auto_cashout_multiplier,
        'cashout_multiplier',q.cashout_multiplier,
        'cashout_source',q.cashout_source,
        'payout',q.payout,
        'cashed_out_at',q.cashed_out_at,
        'payout_transaction_id',q.payout_transaction_id
      )
      order by q.id
    ),
    '[]'::jsonb
  )
  into v_bets
  from (
    select
      b.id,
      b.round_id,
      b.stake,
      b.status,
      b.auto_cashout_multiplier,
      b.cashout_multiplier,
      b.cashout_source,
      b.payout,
      b.cashed_out_at,
      b.payout_transaction_id
    from public.jl_aviator_bets b
    join public.jl_aviator_rounds r
      on r.id=b.round_id
    where b.player_id=v_player
      and r.status in ('OPEN','LOCKED','FLYING','CRASHED','SETTLED')
      and b.created_at>now()-interval '1 day'
    order by b.id desc
    limit 20
  ) q;

  return jsonb_build_object(
    'balance',v_balance,
    'bets',v_bets
  );
end
$$;

revoke all on function public.jl_aviator_player_state(text)
from public;
grant execute on function public.jl_aviator_player_state(text)
to anon,authenticated,service_role;

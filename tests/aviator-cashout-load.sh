#!/usr/bin/env bash
set -euo pipefail

: "${JL_TEST_DATABASE_URL:?Defina JL_TEST_DATABASE_URL para uma base descartavel.}"

PLAYERS="${AVIATOR_LOAD_PLAYERS:-100}"
PARALLEL="${AVIATOR_LOAD_PARALLEL:-25}"
RUN_ID="${AVIATOR_LOAD_RUN_ID:-$(date +%s)-$$}"
PREFIX="p64-${PLAYERS}-${RUN_ID}"
PSQL=(psql "$JL_TEST_DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1)

if ! [[ "$PLAYERS" =~ ^[0-9]+$ ]] || [ "$PLAYERS" -lt 1 ]; then
  echo "AVIATOR_LOAD_PLAYERS inválido: $PLAYERS" >&2
  exit 2
fi

if ! [[ "$PARALLEL" =~ ^[0-9]+$ ]] || [ "$PARALLEL" -lt 1 ]; then
  echo "AVIATOR_LOAD_PARALLEL inválido: $PARALLEL" >&2
  exit 2
fi

"${PSQL[@]}" <<SQL
update public.jl_aviator_rounds
set status='CANCELLED',
    settled_at=coalesce(settled_at,clock_timestamp())
where status in ('OPEN','LOCKED','FLYING','CRASHED');

update public.jl_aviator_settings
set enabled=false,
    one_round_test=false,
    updated_at=clock_timestamp()
where id=true;

update public.jl_aviator_bank
set balance=100000000,
    exposure_ratio=.5,
    updated_at=clock_timestamp()
where id=true;
SQL

round_id=$("${PSQL[@]}" -c "
with engine_lock as (
  select pg_advisory_xact_lock(hashtext('jl_aviator_engine_tick'))
),
enabled as (
  update public.jl_aviator_settings
  set enabled=true,
      one_round_test=false,
      updated_at=clock_timestamp()
  where id=true
  returning 1
)
insert into public.jl_aviator_rounds(status,betting_closes_at,takeoff_at)
select
  'OPEN',
  clock_timestamp()+interval '5 minutes',
  null
from engine_lock,enabled
returning id;
")

"${PSQL[@]}" <<SQL
with created as (
  insert into public.players(name,phone,pin_hash,balance)
  select
    'AVIATOR LOAD '||g::text,
    '$PREFIX-'||g::text,
    'load-only',
    100
  from generate_series(1,$PLAYERS) g
  returning id,phone
)
select count(*) from created;

insert into public.player_sessions(player_id,token_hash,expires_at)
select
  id,
  public.jl_token_hash(phone),
  clock_timestamp()+interval '2 hours'
from public.players
where phone like '$PREFIX-%';

insert into public.jl_aviator_bets(
  round_id,player_id,stake,status,request_key
)
select
  $round_id,
  id,
  10,
  'ACTIVE',
  'load-bet-'||id::text||'-$RUN_ID'
from public.players
where phone like '$PREFIX-%';

begin;

update public.players
set balance=90,
    updated_at=clock_timestamp()
where phone like '$PREFIX-%';

insert into public.transactions(
  id,player_id,kind,amount,status,note,aviator_bet_id,aviator_operation
)
select
  gen_random_uuid(),
  b.player_id,
  'aviator_bet',
  -10,
  'completed',
  'Aposta Aviator rodada '||b.round_id::text,
  b.id,
  'BET'
from public.jl_aviator_bets b
join public.players p on p.id=b.player_id
where b.round_id=$round_id
  and p.phone like '$PREFIX-%';

commit;
SQL

"${PSQL[@]}" -c "select public.jl_aviator_lock_round('$round_id');" >/dev/null
"${PSQL[@]}" <<SQL >/dev/null
update public.jl_aviator_rounds
set betting_closes_at=clock_timestamp()-interval '8 seconds',
    takeoff_at=clock_timestamp()-interval '5 seconds'
where id=$round_id;

select public.jl_aviator_start_round($round_id);

update public.jl_aviator_rounds
set started_at=clock_timestamp()-interval '1 second',
    financial_ceiling=1000000000,
    locked_effective_target=1000000000,
    effective_target=1000000000,
    visual_extension=false,
    engine_due_at=clock_timestamp()+interval '10 minutes'
where id=$round_id;
SQL

jobs="/tmp/aviator-load-${PLAYERS}-${RUN_ID}.tsv"
"${PSQL[@]}" -F $'\t' -c "
select p.phone,b.id
from public.jl_aviator_bets b
join public.players p on p.id=b.player_id
where b.round_id=$round_id
  and p.phone like '$PREFIX-%'
order by b.id;
" > "$jobs"

export JL_TEST_DATABASE_URL
export AVIATOR_LOAD_ROUND_ID="$round_id"
export AVIATOR_LOAD_API_URL="${AVIATOR_LOAD_API_URL:-http://127.0.0.1:54321}"

AVIATOR_LOAD_ANON_KEY="${AVIATOR_LOAD_ANON_KEY:-$(
  supabase status -o env |
  sed -n 's/^ANON_KEY=//p' |
  head -n1 |
  tr -d '"'
)}"
export AVIATOR_LOAD_ANON_KEY

if [ -z "$AVIATOR_LOAD_ANON_KEY" ]; then
  echo "FAIL point64: não foi possível obter ANON_KEY da stack local" >&2
  exit 1
fi

start_ms=$(date +%s%3N)
set +e
node tests/aviator-cashout-http-load.cjs "$jobs"
load_status=$?
set -e
end_ms=$(date +%s%3N)
duration_ms=$((end_ms-start_ms))

if [ "$load_status" -ne 0 ]; then
  echo "FAIL point64: one or more simultaneous HTTP cash-outs failed"
  exit 1
fi

invariants=$("${PSQL[@]}" -c "
select
  (select count(*)
   from public.jl_aviator_bets b
   join public.players p on p.id=b.player_id
   where b.round_id=$round_id
     and p.phone like '$PREFIX-%'
     and b.status='CASHED_OUT')||':'||
  (select count(*)
   from public.transactions t
   join public.jl_aviator_bets b on b.id=t.aviator_bet_id
   join public.players p on p.id=b.player_id
   where b.round_id=$round_id
     and p.phone like '$PREFIX-%'
     and t.aviator_operation='PAYOUT')||':'||
  (select count(*)
   from public.jl_aviator_bets b
   join public.players p on p.id=b.player_id
   where b.round_id=$round_id
     and p.phone like '$PREFIX-%'
     and b.status='ACTIVE')||':'||
  (select count(*)
   from public.jl_aviator_bets b
   join public.players p on p.id=b.player_id
   where b.round_id=$round_id
     and p.phone like '$PREFIX-%'
     and b.payout_transaction_id is null);
")

expected="$PLAYERS:$PLAYERS:0:0"
[[ "$invariants" == "$expected" ]] || {
  echo "FAIL point64 invariants expected=$expected actual=$invariants"
  exit 1
}

"${PSQL[@]}" -c "
update public.jl_aviator_rounds
set status='SETTLED',
    settled_at=clock_timestamp(),
    next_round_at=null
where id=$round_id
  and not exists(
    select 1 from public.jl_aviator_bets
    where round_id=$round_id and status='ACTIVE'
  );
" >/dev/null

throughput=$(awk -v n="$PLAYERS" -v ms="$duration_ms" 'BEGIN { if(ms<=0) ms=1; printf "%.2f", n/(ms/1000) }')

printf '{"players":%s,"parallel":%s,"duration_ms":%s,"cashouts_per_second":%s,"round_id":%s,"financial_divergence":false}\n' \
  "$PLAYERS" "$PARALLEL" "$duration_ms" "$throughput" "$round_id"

echo "PASS aviator point 64: $PLAYERS cash-outs completed with concurrency $PARALLEL; one payout per bet; no active leftovers"

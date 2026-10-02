#!/usr/bin/env bash
set -euo pipefail

: "${JL_TEST_DATABASE_URL:?Defina JL_TEST_DATABASE_URL para uma base descartavel.}"

PSQL=(psql "$JL_TEST_DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1)
PHONE="25899061263"
TOKEN="aviator-point63-restart"

cleanup() {
  "${PSQL[@]}" <<'SQL' >/dev/null 2>&1 || true
update public.jl_aviator_settings
set enabled=false,
    one_round_test=false,
    updated_at=clock_timestamp()
where id=true;

update public.jl_aviator_rounds
set status='CANCELLED',
    settled_at=coalesce(settled_at,clock_timestamp())
where status in ('OPEN','LOCKED','FLYING','CRASHED');

delete from public.jl_aviator_bets
where player_id in (
  select id from public.players where phone='25899061263'
);

delete from public.transactions
where player_id in (
  select id from public.players where phone='25899061263'
);

delete from public.player_sessions
where player_id in (
  select id from public.players where phone='25899061263'
);

delete from public.players where phone='25899061263';
SQL
}
trap cleanup EXIT
cleanup

"${PSQL[@]}" <<'SQL'
update public.jl_aviator_settings
set enabled=false,
    one_round_test=false,
    updated_at=clock_timestamp()
where id=true;

update public.jl_aviator_bank
set balance=100000,
    exposure_ratio=.5,
    updated_at=clock_timestamp()
where id=true;

insert into public.players(name,phone,pin_hash,balance)
values('AVIATOR POINT63 RESTART','25899061263','ci-only',100);


insert into public.player_sessions(player_id,token_hash,expires_at)
select id,public.jl_token_hash('aviator-point63-restart'),clock_timestamp()+interval '1 hour'
from public.players where phone='25899061263';
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
  clock_timestamp()+interval '30 seconds',
  clock_timestamp()+interval '33 seconds'
from engine_lock,enabled
returning id;
")

bet_id=$("${PSQL[@]}" -c "
select (public.jl_aviator_place_bet(
  '$TOKEN',10,'point63-bet-'||'$round_id'
)->>'bet_id')::bigint;
")

"${PSQL[@]}" -c "select public.jl_aviator_lock_round('$round_id');" >/dev/null
"${PSQL[@]}" -c "
update public.jl_aviator_rounds
set betting_closes_at=clock_timestamp()-interval '8 seconds',
    takeoff_at=clock_timestamp()-interval '5 seconds'
where id='$round_id';

select public.jl_aviator_start_round('$round_id');

update public.jl_aviator_rounds
set started_at=clock_timestamp()-interval '2 seconds',
    financial_ceiling=50,
    locked_effective_target=50,
    effective_target=50,
    visual_extension=false,
    engine_due_at=clock_timestamp()+interval '10 minutes'
where id='$round_id';
" >/dev/null

before=$("${PSQL[@]}" -c "
select
  r.status||':'||
  b.status||':'||
  p.balance::text
from public.jl_aviator_rounds r
join public.jl_aviator_bets b on b.round_id=r.id
join public.players p on p.id=b.player_id
where r.id='$round_id'
  and b.id='$bet_id';
")

[[ "$before" == FLYING:ACTIVE:90* ]] || {
  echo "FAIL point63 pre-restart state: $before"
  exit 1
}

supabase stop >/tmp/aviator-point63-stop.log 2>&1
KONG_NGINX_WORKER_PROCESSES=auto supabase start >/tmp/aviator-point63-start.log 2>&1

ready=0
for _ in $(seq 1 60); do
  if "${PSQL[@]}" -c "select 1" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done

[[ "$ready" -eq 1 ]] || {
  echo "FAIL point63: local server did not return after restart"
  cat /tmp/aviator-point63-stop.log /tmp/aviator-point63-start.log
  exit 1
}

snapshot=$("${PSQL[@]}" -c "
select public.jl_aviator_reconnect('$TOKEN');
")

echo "$snapshot" | grep -q '"status": "FLYING"' || {
  echo "FAIL point63: reconnect did not recover FLYING after restart: $snapshot"
  exit 1
}

echo "$snapshot" | grep -q '"status": "ACTIVE"' || {
  echo "FAIL point63: active bet was not recovered after restart: $snapshot"
  exit 1
}

cashout=$("${PSQL[@]}" -c "
select public.jl_aviator_cashout(
  '$TOKEN',
  '$bet_id',
  'point63-cashout-'||'$round_id'
);
")

echo "$cashout" | grep -q '"ok": true' || {
  echo "FAIL point63: cash-out failed after server restart: $cashout"
  exit 1
}

invariants=$("${PSQL[@]}" -c "
select
  (select status from public.jl_aviator_bets where id='$bet_id')||':'||
  (select count(*) from public.transactions
    where aviator_bet_id='$bet_id' and aviator_operation='PAYOUT')||':'||
  (select (balance>=90)::text from public.players where phone='$PHONE')||':'||
  (select count(*) from public.jl_aviator_bets
    where id='$bet_id' and payout_transaction_id is not null);
")

[[ "$invariants" == "CASHED_OUT:1:true:1" ]] || {
  echo "FAIL point63 post-restart financial invariants: $invariants"
  exit 1
}

echo "PASS aviator point 63: full local server restart during FLYING preserves round, bet, reconnect and cash-out"

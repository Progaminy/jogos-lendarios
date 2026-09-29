#!/usr/bin/env bash
set -euo pipefail

: "${JL_TEST_DATABASE_URL:?Defina JL_TEST_DATABASE_URL para uma base descartavel.}"

PSQL=(psql "$JL_TEST_DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1)
PHONE='25899061203'
TOKEN='aviator-same-bet'

cleanup() {
  "${PSQL[@]}" <<SQL >/dev/null 2>&1 || true
update public.jl_aviator_rounds
set status='CANCELLED',
    settled_at=coalesce(settled_at,clock_timestamp())
where status in ('OPEN','LOCKED','FLYING','CRASHED');

delete from public.jl_aviator_bets
where player_id in (
  select id from public.players where phone='$PHONE'
);

delete from public.transactions
where player_id in (
  select id from public.players where phone='$PHONE'
);

delete from public.player_sessions
where player_id in (
  select id from public.players where phone='$PHONE'
);

delete from public.players where phone='$PHONE';
SQL
}
trap cleanup EXIT
cleanup

"${PSQL[@]}" <<SQL
update public.jl_aviator_settings
set enabled=true,
    one_round_test=false,
    updated_at=clock_timestamp()
where id=true;

update public.jl_aviator_bank
set balance=100000,
    exposure_ratio=.5,
    updated_at=clock_timestamp()
where id=true;

insert into public.players(name,phone,pin_hash,balance)
values('AVIATOR SAME BET','$PHONE','ci-only',1000);

insert into public.player_sessions(player_id,token_hash,expires_at)
select id,public.jl_token_hash('$TOKEN'),now()+interval '1 hour'
from public.players where phone='$PHONE';
SQL

round_id=$("${PSQL[@]}" -c "
insert into public.jl_aviator_rounds(
  status,betting_closes_at,takeoff_at
)
values(
  'OPEN',
  clock_timestamp()+interval '1 minute',
  clock_timestamp()+interval '63 seconds'
)
returning id;
")

bet_id=$("${PSQL[@]}" -c "
select (public.jl_aviator_place_bet(
  '$TOKEN',10,'same-bet-request-'||'$round_id'
)->>'bet_id')::bigint;
")

"${PSQL[@]}" -c "select public.jl_aviator_lock_round('$round_id');" >/dev/null
"${PSQL[@]}" -c "
update public.jl_aviator_rounds
set betting_closes_at=clock_timestamp()-interval '4 seconds',
    takeoff_at=clock_timestamp()-interval '1 second'
where id='$round_id';
select public.jl_aviator_start_round('$round_id');
update public.jl_aviator_rounds
set started_at=clock_timestamp()-interval '.5 second'
where id='$round_id';
" >/dev/null

# Segura a banca para garantir sobreposicao real entre os dois submits.
"${PSQL[@]}" -c "
begin;
select balance from public.jl_aviator_bank where id=true for update;
select pg_sleep(.5);
commit;
" >/tmp/aviator-same-bank.out 2>/tmp/aviator-same-bank.err &
bank_pid=$!

sleep .05

"${PSQL[@]}" -c "
select public.jl_aviator_cashout('$TOKEN','$bet_id');
" >/tmp/aviator-same-a.out 2>/tmp/aviator-same-a.err &
pid_a=$!

"${PSQL[@]}" -c "
select public.jl_aviator_cashout('$TOKEN','$bet_id');
" >/tmp/aviator-same-b.out 2>/tmp/aviator-same-b.err &
pid_b=$!

wait "$bank_pid"
wait "$pid_a" || { cat /tmp/aviator-same-a.err; exit 1; }
wait "$pid_b" || { cat /tmp/aviator-same-b.err; exit 1; }

retry=$("${PSQL[@]}" -c "
select public.jl_aviator_cashout('$TOKEN','$bet_id');
")

invariants=$("${PSQL[@]}" -c "
select
  (select status from public.jl_aviator_bets where id='$bet_id')||':'||
  (select count(*) from public.transactions t
     join public.players p on p.id=t.player_id
    where p.phone='$PHONE' and t.kind='aviator_payout')||':'||
  (select count(*) from public.jl_aviator_bank_ledger
    where request_key='cashout:$bet_id')||':'||
  (select count(*) from public.audit_log
    where action='aviator.cashout'
      and details->>'betId'='$bet_id')||':'||
  (select (
      p.balance=round(990+b.payout,2)
    )::text
    from public.players p
    join public.jl_aviator_bets b on b.player_id=p.id
    where p.phone='$PHONE' and b.id='$bet_id')||':'||
  (select (
      exists(
        select 1 from public.transactions t
        where t.id=b.payout_transaction_id
          and t.kind='aviator_payout'
          and t.amount=b.payout
      )
    )::text
    from public.jl_aviator_bets b
    where b.id='$bet_id');
")

[[ "$invariants" == "CASHED_OUT:1:1:1:true:true" ]] || {
  echo "FAIL same-bet atomic cashout invariants: $invariants"
  echo "A:"; cat /tmp/aviator-same-a.out /tmp/aviator-same-a.err
  echo "B:"; cat /tmp/aviator-same-b.out /tmp/aviator-same-b.err
  echo "Retry: $retry"
  exit 1
}

false_count=$(cat /tmp/aviator-same-a.out /tmp/aviator-same-b.out | grep -o '"already_processed": false' | wc -l | tr -d ' ')
true_count=$(cat /tmp/aviator-same-a.out /tmp/aviator-same-b.out | grep -o '"already_processed": true' | wc -l | tr -d ' ')

[[ "$false_count" == "1" && "$true_count" == "1" ]] || {
  echo "FAIL expected one processed and one idempotent response: false=$false_count true=$true_count"
  cat /tmp/aviator-same-a.out /tmp/aviator-same-b.out
  exit 1
}

echo "$retry" | grep -q '"already_processed": true' || {
  echo "FAIL retry after completed cash-out was not idempotent: $retry"
  exit 1
}

echo "PASS aviator: same bet concurrent cash-out pays exactly once and retries are stable"

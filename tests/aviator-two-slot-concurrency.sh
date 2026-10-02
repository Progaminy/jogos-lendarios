#!/usr/bin/env bash
set -euo pipefail

: "${JL_TEST_DATABASE_URL:?Defina JL_TEST_DATABASE_URL para uma base descartavel.}"

PSQL=(psql "$JL_TEST_DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1)
PHONE='25899061262'
TOKEN='aviator-two-slot-race'

cleanup() {
  "${PSQL[@]}" <<SQL >/dev/null 2>&1 || true
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
insert into public.players(name,phone,pin_hash,balance)
values('AVIATOR TWO SLOT RACE','$PHONE','ci-only',100);

insert into public.player_sessions(player_id,token_hash,expires_at)
select id,public.jl_token_hash('$TOKEN'),clock_timestamp()+interval '1 hour'
from public.players where phone='$PHONE';
SQL

create_round() {
  "${PSQL[@]}" -c "
update public.jl_aviator_settings
set enabled=false,
    one_round_test=false,
    updated_at=clock_timestamp()
where id=true;

update public.jl_aviator_rounds
set status='CANCELLED',
    settled_at=coalesce(settled_at,clock_timestamp())
where status in ('OPEN','LOCKED','FLYING','CRASHED');

insert into public.jl_aviator_rounds(
  status,betting_closes_at,takeoff_at
)
values(
  'OPEN',
  clock_timestamp()+interval '1 minute',
  clock_timestamp()+interval '63 seconds'
)
returning id;
" | tail -n1
}

enable_game() {
  "${PSQL[@]}" -c "
update public.jl_aviator_settings
set enabled=true,
    one_round_test=false,
    updated_at=clock_timestamp()
where id=true;
" >/dev/null
}

# Fase A: duas abas tentam usar o MESMO slot 1.
round_a=$(create_round)
enable_game

set +e
"${PSQL[@]}" -c "
select public.jl_aviator_place_bet_slot(
  '$TOKEN',10,'two-slot-race-a-'||'$round_a',null,1
);
" >/tmp/aviator-slot-race-a.out 2>/tmp/aviator-slot-race-a.err &
pid_a=$!

"${PSQL[@]}" -c "
select public.jl_aviator_place_bet_slot(
  '$TOKEN',10,'two-slot-race-b-'||'$round_a',null,1
);
" >/tmp/aviator-slot-race-b.out 2>/tmp/aviator-slot-race-b.err &
pid_b=$!

wait "$pid_a"; status_a=$?
wait "$pid_b"; status_b=$?
set -e

successes=0
[[ "$status_a" -eq 0 ]] && successes=$((successes+1))
[[ "$status_b" -eq 0 ]] && successes=$((successes+1))

[[ "$successes" -eq 1 ]] || {
  echo "FAIL two-slot phase A: expected one slot-1 winner; a=$status_a b=$status_b"
  cat /tmp/aviator-slot-race-a.out /tmp/aviator-slot-race-a.err
  cat /tmp/aviator-slot-race-b.out /tmp/aviator-slot-race-b.err
  exit 1
}

for err in /tmp/aviator-slot-race-a.err /tmp/aviator-slot-race-b.err; do
  if [[ -s "$err" ]]; then
    grep -q "Ja existe uma aposta neste painel nesta rodada" "$err" || {
      echo "FAIL two-slot phase A: unexpected loser error"
      cat "$err"
      exit 1
    }
  fi
done

phase_a=$("${PSQL[@]}" -c "
select
  (select count(*) from public.jl_aviator_bets b
   join public.players p on p.id=b.player_id
   where p.phone='$PHONE' and b.round_id=$round_a and b.bet_slot=1)||':'||
  (select count(*) from public.transactions t
   join public.jl_aviator_bets b on b.id=t.aviator_bet_id
   join public.players p on p.id=b.player_id
   where p.phone='$PHONE' and b.round_id=$round_a and t.aviator_operation='BET')||':'||
  (select balance::text from public.players where phone='$PHONE');
")

[[ "$phase_a" == "1:1:90.00" || "$phase_a" == "1:1:90" ]] || {
  echo "FAIL two-slot phase A invariants: $phase_a"
  exit 1
}

bet_a=$("${PSQL[@]}" -c "
select b.id
from public.jl_aviator_bets b
join public.players p on p.id=b.player_id
where p.phone='$PHONE' and b.round_id=$round_a and b.bet_slot=1
limit 1;
")

"${PSQL[@]}" -c "
select public.jl_aviator_cancel_bet(
  '$TOKEN',
  $bet_a,
  'two-slot-race-refund-'||'$round_a'
);
" >/dev/null

# Fase B: slots 1 e 2 chegam simultaneamente. Ambos devem entrar.
round_b=$(create_round)
enable_game

set +e
"${PSQL[@]}" -c "
select public.jl_aviator_place_bet_slot(
  '$TOKEN',10,'two-slot-race-slot1-'||'$round_b',null,1
);
" >/tmp/aviator-slot-race-c.out 2>/tmp/aviator-slot-race-c.err &
pid_c=$!

"${PSQL[@]}" -c "
select public.jl_aviator_place_bet_slot(
  '$TOKEN',10,'two-slot-race-slot2-'||'$round_b',2.00,2
);
" >/tmp/aviator-slot-race-d.out 2>/tmp/aviator-slot-race-d.err &
pid_d=$!

wait "$pid_c"; status_c=$?
wait "$pid_d"; status_d=$?
set -e

[[ "$status_c" -eq 0 && "$status_d" -eq 0 ]] || {
  echo "FAIL two-slot phase B: both independent slots must succeed; c=$status_c d=$status_d"
  cat /tmp/aviator-slot-race-c.out /tmp/aviator-slot-race-c.err
  cat /tmp/aviator-slot-race-d.out /tmp/aviator-slot-race-d.err
  exit 1
}

phase_b=$("${PSQL[@]}" -c "
select
  (select count(*) from public.jl_aviator_bets b
   join public.players p on p.id=b.player_id
   where p.phone='$PHONE' and b.round_id=$round_b and b.status='ACTIVE')||':'||
  (select count(distinct b.bet_slot) from public.jl_aviator_bets b
   join public.players p on p.id=b.player_id
   where p.phone='$PHONE' and b.round_id=$round_b)||':'||
  (select count(*) from public.transactions t
   join public.jl_aviator_bets b on b.id=t.aviator_bet_id
   join public.players p on p.id=b.player_id
   where p.phone='$PHONE' and b.round_id=$round_b and t.aviator_operation='BET')||':'||
  (select balance::text from public.players where phone='$PHONE');
")

[[ "$phase_b" == "2:2:2:80.00" || "$phase_b" == "2:2:2:80" ]] || {
  echo "FAIL two-slot phase B invariants: $phase_b"
  exit 1
}

echo "PASS aviator two-slot concurrency: same slot pays/debits once; slots 1 and 2 can bet concurrently"

#!/usr/bin/env bash
set -euo pipefail

: "${JL_TEST_DATABASE_URL:?Defina JL_TEST_DATABASE_URL para uma base descartavel.}"

PSQL=(psql "$JL_TEST_DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1)

cleanup() {
  "${PSQL[@]}" <<'SQL' >/dev/null 2>&1 || true
update public.jl_aviator_rounds
set status='CANCELLED',
    settled_at=coalesce(settled_at,clock_timestamp())
where status in ('OPEN','LOCKED','FLYING','CRASHED');

delete from public.transactions
where player_id in (
  select id from public.players
  where phone in ('25899061201','25899061202')
);

delete from public.jl_aviator_bets
where player_id in (
  select id from public.players
  where phone in ('25899061201','25899061202')
);

delete from public.player_sessions
where player_id in (
  select id from public.players
  where phone in ('25899061201','25899061202')
);

delete from public.players
where phone in ('25899061201','25899061202');
SQL
}
trap cleanup EXIT
cleanup

"${PSQL[@]}" <<'SQL'
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
values
 ('AVIATOR CASHOUT A','25899061201','ci-only',1000),
 ('AVIATOR CASHOUT B','25899061202','ci-only',1000);

insert into public.player_sessions(player_id,token_hash,expires_at)
select id,public.jl_token_hash('aviator-co-a'),now()+interval '1 hour'
from public.players where phone='25899061201'
union all
select id,public.jl_token_hash('aviator-co-b'),now()+interval '1 hour'
from public.players where phone='25899061202';
SQL

round_id=$("${PSQL[@]}" -c "
insert into public.jl_aviator_rounds(status,betting_closes_at)
values('OPEN',clock_timestamp()+interval '1 minute')
returning id;
")

bet_a=$("${PSQL[@]}" -c "
select (public.jl_aviator_place_bet(
  'aviator-co-a',10,'aviator-co-a-request-'||'$round_id'
)->>'bet_id')::bigint;
")
bet_b=$("${PSQL[@]}" -c "
select (public.jl_aviator_place_bet(
  'aviator-co-b',10,'aviator-co-b-request-'||'$round_id'
)->>'bet_id')::bigint;
")

"${PSQL[@]}" -c "select public.jl_aviator_lock_round('$round_id');" >/dev/null
"${PSQL[@]}" -c "
update public.jl_aviator_rounds
set status='FLYING',
    started_at=clock_timestamp()-interval '.5 second'
where id='$round_id';
" >/dev/null

# Segura a banca por um instante para fazer os dois cash-outs se sobreporem.
"${PSQL[@]}" -c "
begin;
select balance from public.jl_aviator_bank where id=true for update;
select pg_sleep(.5);
commit;
" >/tmp/aviator-bank-block.out 2>/tmp/aviator-bank-block.err &
bank_pid=$!

sleep .05

"${PSQL[@]}" -c "
select public.jl_aviator_cashout('aviator-co-a','$bet_a');
" >/tmp/aviator-co-a.out 2>/tmp/aviator-co-a.err &
pid_a=$!

"${PSQL[@]}" -c "
select public.jl_aviator_cashout('aviator-co-b','$bet_b');
" >/tmp/aviator-co-b.out 2>/tmp/aviator-co-b.err &
pid_b=$!

wait "$bank_pid"
wait "$pid_a" || { cat /tmp/aviator-co-a.err; exit 1; }
wait "$pid_b" || { cat /tmp/aviator-co-b.err; exit 1; }

result=$("${PSQL[@]}" -c "
select
  (select count(*) from public.jl_aviator_bets
    where round_id='$round_id' and status='CASHED_OUT')||':'||
  (select count(*) from public.jl_aviator_bets
    where round_id='$round_id' and status='ACTIVE')||':'||
  (select count(*) from public.transactions t
    join public.players p on p.id=t.player_id
    where p.phone in ('25899061201','25899061202')
      and t.kind='aviator_payout')||':'||
  (select visual_extension::text from public.jl_aviator_rounds where id='$round_id')||':'||
  (select (zero_exposure_at_multiplier is not null)::text
     from public.jl_aviator_rounds where id='$round_id')||':'||
  (select (
      effective_target >= zero_exposure_at_multiplier
      and effective_target >= visual_target
    )::text
     from public.jl_aviator_rounds where id='$round_id');
")

[[ "$result" == "2:0:2:true:true:true" ]] || {
  echo "FAIL concurrent cashout invariant: $result"
  echo "A:"; cat /tmp/aviator-co-a.out /tmp/aviator-co-a.err
  echo "B:"; cat /tmp/aviator-co-b.out /tmp/aviator-co-b.err
  exit 1
}

echo "PASS aviator: two concurrent cash-outs, one payout each, final visual extension consistent"

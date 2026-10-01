#!/usr/bin/env bash
set -euo pipefail

: "${JL_TEST_DATABASE_URL:?Defina JL_TEST_DATABASE_URL para uma base descartavel.}"

PSQL=(psql "$JL_TEST_DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1)
PHONE='25899061260'
TOKEN_OLD='aviator-point60-old'
TOKEN_NEW='aviator-point60-new'

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
values('AVIATOR POINT60 SAME ACCOUNT','$PHONE','ci-only',1000);

insert into public.player_sessions(player_id,token_hash,expires_at)
select id,public.jl_token_hash('$TOKEN_OLD'),now()+interval '1 hour'
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

# Duas abas da MESMA sessão tentam apostar simultaneamente na mesma rodada,
# com chaves e valores diferentes. Apenas uma pode vencer.
set +e
"${PSQL[@]}" -c "
select public.jl_aviator_place_bet(
  '$TOKEN_OLD',10,'point60-tab-a-'||'$round_id'
);
" >/tmp/aviator-point60-tab-a.out 2>/tmp/aviator-point60-tab-a.err &
pid_a=$!

"${PSQL[@]}" -c "
select public.jl_aviator_place_bet(
  '$TOKEN_OLD',20,'point60-tab-b-'||'$round_id'
);
" >/tmp/aviator-point60-tab-b.out 2>/tmp/aviator-point60-tab-b.err &
pid_b=$!

wait "$pid_a"; status_a=$?
wait "$pid_b"; status_b=$?
set -e

successes=0
[[ "$status_a" -eq 0 ]] && successes=$((successes+1))
[[ "$status_b" -eq 0 ]] && successes=$((successes+1))

[[ "$successes" -eq 1 ]] || {
  echo "FAIL point60: expected exactly one simultaneous bet success; a=$status_a b=$status_b"
  echo "A OUT:"; cat /tmp/aviator-point60-tab-a.out
  echo "A ERR:"; cat /tmp/aviator-point60-tab-a.err
  echo "B OUT:"; cat /tmp/aviator-point60-tab-b.out
  echo "B ERR:"; cat /tmp/aviator-point60-tab-b.err
  exit 1
}

# A tentativa perdedora deve ser bloqueada como segunda aposta da rodada,
# não por corrupção financeira.
if [[ "$status_a" -ne 0 ]]; then
  grep -q "Ja existe uma aposta nesta rodada" /tmp/aviator-point60-tab-a.err || {
    echo "FAIL point60: tab A failed for unexpected reason"
    cat /tmp/aviator-point60-tab-a.err
    exit 1
  }
fi

if [[ "$status_b" -ne 0 ]]; then
  grep -q "Ja existe uma aposta nesta rodada" /tmp/aviator-point60-tab-b.err || {
    echo "FAIL point60: tab B failed for unexpected reason"
    cat /tmp/aviator-point60-tab-b.err
    exit 1
  }
fi

invariants=$("${PSQL[@]}" -c "
select
  (select count(*)
     from public.jl_aviator_bets b
     join public.players p on p.id=b.player_id
    where p.phone='$PHONE' and b.round_id='$round_id')||':'||
  (select count(*)
     from public.transactions t
     join public.players p on p.id=t.player_id
    where p.phone='$PHONE'
      and t.kind='aviator_bet'
      and t.aviator_operation='BET')||':'||
  (select (
      p.balance=round(1000-b.stake,2)
    )::text
     from public.players p
     join public.jl_aviator_bets b on b.player_id=p.id
    where p.phone='$PHONE' and b.round_id='$round_id')||':'||
  (select (
      exists(
        select 1
        from public.transactions t
        where t.aviator_bet_id=b.id
          and t.aviator_operation='BET'
          and t.amount=-b.stake
      )
    )::text
     from public.players p
     join public.jl_aviator_bets b on b.player_id=p.id
    where p.phone='$PHONE' and b.round_id='$round_id');
")

[[ "$invariants" == "1:1:true:true" ]] || {
  echo "FAIL point60: same-session tab invariants: $invariants"
  exit 1
}

# Segundo LOGIN da mesma conta: o mais recente vence e revoga o anterior.
"${PSQL[@]}" -c "
insert into public.player_sessions(player_id,token_hash,expires_at)
select id,public.jl_token_hash('$TOKEN_NEW'),now()+interval '1 hour'
from public.players where phone='$PHONE';
" >/dev/null

old_status=0
set +e
"${PSQL[@]}" -c "
select public.jl_aviator_reconnect('$TOKEN_OLD');
" >/tmp/aviator-point60-old.out 2>/tmp/aviator-point60-old.err
old_status=$?
set -e

[[ "$old_status" -ne 0 ]] || {
  echo "FAIL point60: old login still authenticated after newer login"
  cat /tmp/aviator-point60-old.out
  exit 1
}

grep -q "Sessão do jogador inválida ou expirada" /tmp/aviator-point60-old.err || {
  echo "FAIL point60: old login rejected for unexpected reason"
  cat /tmp/aviator-point60-old.err
  exit 1
}

new_state=$("${PSQL[@]}" -c "
select public.jl_aviator_reconnect('$TOKEN_NEW');
")

echo "$new_state" | grep -q '"player"' || {
  echo "FAIL point60: newest login cannot reconnect to Aviator: $new_state"
  exit 1
}

session_count=$("${PSQL[@]}" -c "
select count(*)
from public.player_sessions s
join public.players p on p.id=s.player_id
where p.phone='$PHONE'
  and s.expires_at>now();
")

[[ "$session_count" == "1" ]] || {
  echo "FAIL point60: expected exactly one surviving login, got $session_count"
  exit 1
}

echo "PASS aviator point 60: two tabs cannot double-bet; newest login invalidates the previous session"

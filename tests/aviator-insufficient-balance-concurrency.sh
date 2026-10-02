#!/usr/bin/env bash
set -euo pipefail

: "${JL_TEST_DATABASE_URL:?Defina JL_TEST_DATABASE_URL para uma base descartavel.}"

PSQL=(psql "$JL_TEST_DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1)

PHONE_LOW='25899061261'
TOKEN_LOW='aviator-point61-low'
PHONE_EXACT='25899061264'
TOKEN_EXACT='aviator-point61-exact'

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

-- Apagar primeiro o ledger: transactions.aviator_bet_id referencia jl_aviator_bets.
-- A ordem inversa pode abortar o cleanup e deixar fixtures para o teste seguinte.
delete from public.transactions
where player_id in (
  select id
  from public.players
  where phone in ('$PHONE_LOW','$PHONE_EXACT')
);

delete from public.jl_aviator_bets
where player_id in (
  select id
  from public.players
  where phone in ('$PHONE_LOW','$PHONE_EXACT')
);

delete from public.player_sessions
where player_id in (
  select id
  from public.players
  where phone in ('$PHONE_LOW','$PHONE_EXACT')
);

delete from public.players
where phone in ('$PHONE_LOW','$PHONE_EXACT');
SQL
}
trap cleanup EXIT
cleanup

"${PSQL[@]}" <<SQL
update public.jl_aviator_settings
set enabled=false,
    one_round_test=false,
    updated_at=clock_timestamp()
where id=true;

insert into public.players(name,phone,pin_hash,balance)
values('AVIATOR POINT61 INSUFFICIENT','$PHONE_LOW','ci-only',9);

insert into public.player_sessions(player_id,token_hash,expires_at)
select id,public.jl_token_hash('$TOKEN_LOW'),now()+interval '1 hour'
from public.players
where phone='$PHONE_LOW';
SQL

round_1=$("${PSQL[@]}" -c "
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

"${PSQL[@]}" -c "
update public.jl_aviator_settings
set enabled=true,
    one_round_test=false,
    updated_at=clock_timestamp()
where id=true;
" >/dev/null

# Fase A: saldo 9 MZN; duas apostas simultâneas de 10 MZN.
# Ambas precisam falhar e nenhuma pode produzir débito/aposta parcial.
set +e
"${PSQL[@]}" -c "
select public.jl_aviator_place_bet(
  '$TOKEN_LOW',10,'point61-insufficient-a-'||'$round_1'
);
" >/tmp/aviator-point61-a.out 2>/tmp/aviator-point61-a.err &
pid_a=$!

"${PSQL[@]}" -c "
select public.jl_aviator_place_bet(
  '$TOKEN_LOW',10,'point61-insufficient-b-'||'$round_1'
);
" >/tmp/aviator-point61-b.out 2>/tmp/aviator-point61-b.err &
pid_b=$!

wait "$pid_a"; status_a=$?
wait "$pid_b"; status_b=$?
set -e

[[ "$status_a" -ne 0 && "$status_b" -ne 0 ]] || {
  echo "FAIL point61 phase A: insufficient concurrent bets unexpectedly succeeded; a=$status_a b=$status_b"
  cat /tmp/aviator-point61-a.out /tmp/aviator-point61-a.err
  cat /tmp/aviator-point61-b.out /tmp/aviator-point61-b.err
  exit 1
}

grep -q "Saldo insuficiente" /tmp/aviator-point61-a.err || {
  echo "FAIL point61 phase A: attempt A failed for unexpected reason"
  cat /tmp/aviator-point61-a.err
  exit 1
}

grep -q "Saldo insuficiente" /tmp/aviator-point61-b.err || {
  echo "FAIL point61 phase A: attempt B failed for unexpected reason"
  cat /tmp/aviator-point61-b.err
  exit 1
}

phase_a=$("${PSQL[@]}" -c "
select
  (select balance::text
     from public.players
    where phone='$PHONE_LOW')||':'||
  (select count(*)
     from public.jl_aviator_bets b
     join public.players p on p.id=b.player_id
    where p.phone='$PHONE_LOW')||':'||
  (select count(*)
     from public.transactions t
     join public.players p on p.id=t.player_id
    where p.phone='$PHONE_LOW'
      and t.kind='aviator_bet');
")

[[ "$phase_a" == "9.00:0:0" || "$phase_a" == "9:0:0" ]] || {
  echo "FAIL point61 phase A: insufficient bets left partial effects: $phase_a"
  exit 1
}

# Encerra a primeira rodada e cria outro jogador que nasce com exatamente
# 10 MZN. O próprio insert do jogador cria o lançamento inicial reconciliado
# no ledger, sem ajuste artificial de balance.
"${PSQL[@]}" <<SQL
update public.jl_aviator_settings
set enabled=false,
    one_round_test=false,
    updated_at=clock_timestamp()
where id=true;

update public.jl_aviator_rounds
set status='CANCELLED',
    settled_at=clock_timestamp()
where id='$round_1';

insert into public.players(name,phone,pin_hash,balance)
values('AVIATOR POINT61 EXACT','$PHONE_EXACT','ci-only',10);

insert into public.player_sessions(player_id,token_hash,expires_at)
select id,public.jl_token_hash('$TOKEN_EXACT'),now()+interval '1 hour'
from public.players
where phone='$PHONE_EXACT';
SQL

round_2=$("${PSQL[@]}" -c "
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

"${PSQL[@]}" -c "
update public.jl_aviator_settings
set enabled=true,
    one_round_test=false,
    updated_at=clock_timestamp()
where id=true;
" >/dev/null

# Fase B: saldo exatamente 10 MZN; duas apostas simultâneas de 10 MZN.
# O lock da carteira deve permitir um único débito.
set +e
"${PSQL[@]}" -c "
select public.jl_aviator_place_bet(
  '$TOKEN_EXACT',10,'point61-exact-a-'||'$round_2'
);
" >/tmp/aviator-point61-c.out 2>/tmp/aviator-point61-c.err &
pid_c=$!

"${PSQL[@]}" -c "
select public.jl_aviator_place_bet(
  '$TOKEN_EXACT',10,'point61-exact-b-'||'$round_2'
);
" >/tmp/aviator-point61-d.out 2>/tmp/aviator-point61-d.err &
pid_d=$!

wait "$pid_c"; status_c=$?
wait "$pid_d"; status_d=$?
set -e

successes=0
[[ "$status_c" -eq 0 ]] && successes=$((successes+1))
[[ "$status_d" -eq 0 ]] && successes=$((successes+1))

[[ "$successes" -eq 1 ]] || {
  echo "FAIL point61 phase B: expected exactly one success; c=$status_c d=$status_d"
  cat /tmp/aviator-point61-c.out /tmp/aviator-point61-c.err
  cat /tmp/aviator-point61-d.out /tmp/aviator-point61-d.err
  exit 1
}

if [[ "$status_c" -ne 0 ]]; then
  grep -Eq "Ja existe uma aposta nesta rodada|Saldo insuficiente" /tmp/aviator-point61-c.err || {
    echo "FAIL point61 phase B: attempt C failed for unexpected reason"
    cat /tmp/aviator-point61-c.err
    exit 1
  }
fi

if [[ "$status_d" -ne 0 ]]; then
  grep -Eq "Ja existe uma aposta nesta rodada|Saldo insuficiente" /tmp/aviator-point61-d.err || {
    echo "FAIL point61 phase B: attempt D failed for unexpected reason"
    cat /tmp/aviator-point61-d.err
    exit 1
  }
fi

phase_b=$("${PSQL[@]}" -c "
select
  (select balance::text
     from public.players
    where phone='$PHONE_EXACT')||':'||
  (select count(*)
     from public.jl_aviator_bets b
     join public.players p on p.id=b.player_id
    where p.phone='$PHONE_EXACT'
      and b.round_id='$round_2')||':'||
  (select count(*)
     from public.transactions t
     join public.players p on p.id=t.player_id
    where p.phone='$PHONE_EXACT'
      and t.kind='aviator_bet'
      and t.aviator_operation='BET')||':'||
  (select (balance>=0)::text
     from public.players
    where phone='$PHONE_EXACT')||':'||
  (
    select exists(
      select 1
      from public.jl_aviator_bets b
      join public.players p on p.id=b.player_id
      join public.transactions t
        on t.aviator_bet_id=b.id
       and t.aviator_operation='BET'
      where p.phone='$PHONE_EXACT'
        and b.round_id='$round_2'
        and t.amount=-b.stake
    )::text
  );
")

[[ "$phase_b" == "0.00:1:1:true:true" || "$phase_b" == "0:1:1:true:true" ]] || {
  echo "FAIL point61 phase B: wallet concurrency invariant failed: $phase_b"
  exit 1
}

# A aposta vencedora da fase B precisa ser reembolsada antes de a rodada ser
# finalizada pelo cleanup, para não contaminar a certificação financeira seguinte.
bet_id=$("${PSQL[@]}" -c "
select b.id
from public.jl_aviator_bets b
join public.players p on p.id=b.player_id
where p.phone='$PHONE_EXACT'
  and b.round_id='$round_2'
  and b.status='ACTIVE'
limit 1;
")

if [[ -n "$bet_id" ]]; then
  "${PSQL[@]}" -c "
  select public.jl_aviator_cancel_bet(
    '$TOKEN_EXACT',
    $bet_id,
    'point61-final-refund-'||'$round_2'
  );
  " >/dev/null
fi
echo "PASS aviator point 61: insufficient simultaneous bets leave no effects; exact-balance race permits one debit only and never goes negative"

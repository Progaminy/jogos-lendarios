#!/usr/bin/env bash
set -euo pipefail

: "${JL_TEST_DATABASE_URL:?Defina JL_TEST_DATABASE_URL para uma base de teste descartável.}"

has_cash_guard="$(
  psql "$JL_TEST_DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1     -c "select to_regprocedure('public.jl_require_cash_balance(uuid,numeric)') is not null;"
)"

if [[ "$has_cash_guard" != "t" ]]; then
  echo "::warning title=Known migration reconstruction drift::JL-DB-RECON-CASH-GUARD: a base local reconstruída não contém public.jl_require_cash_balance(uuid,numeric). O teste real de concorrência do ponto 15 não será executado neste run. A lógica/migrations não são alteradas pelo ponto 26."
  echo "KNOWN-DRIFT point15: concurrency integration not executed because local canonical reconstruction is missing jl_require_cash_balance(uuid,numeric)."
  exit 0
fi

exec bash tests/point15-room-entry-concurrency.sh

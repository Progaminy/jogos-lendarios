begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(5);

select ok(
  pg_get_constraintdef(
    (
      select oid
      from pg_constraint
      where conrelid='public.deposit_wager_usages'::regclass
        and conname='deposit_wager_usages_source_type_check'
    )
  ) ilike '%aviator_bet%',
  'Depósito jogado: Aviator é uma origem válida'
);

select ok(
  to_regprocedure('public.jl_aviator_wager_reference(bigint)') is not null,
  'Depósito jogado: referência determinística do Aviator existe'
);

select ok(
  exists(
    select 1
    from pg_trigger
    where tgrelid='public.jl_aviator_bets'::regclass
      and tgname='jl_aviator_deposit_wager_track'
      and not tgisinternal
  ),
  'Depósito jogado: apostas Aviator são rastreadas por trigger'
);

select ok(
  pg_get_functiondef('public.jl_track_aviator_deposit_wager()'::regprocedure)
    like '%jl_apply_cash_wager%'
  and pg_get_functiondef('public.jl_track_aviator_deposit_wager()'::regprocedure)
    like '%jl_reverse_cash_wager%',
  'Depósito jogado: aposta libera e reembolso volta a bloquear'
);

select ok(
  pg_get_functiondef('public.jl_apply_cash_wager(uuid,numeric,text,uuid)'::regprocedure)
    like '%aviator_bet%',
  'Depósito jogado: função central aceita Aviator'
);

select * from finish();
rollback;

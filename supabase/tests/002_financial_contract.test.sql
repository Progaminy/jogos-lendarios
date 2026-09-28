begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(24);

select ok(
  exists(
    select 1 from pg_constraint
    where conrelid='public.players'::regclass
      and conname in ('players_balance_check','players_balance_nonnegative_ck')
  ),
  'Finanças: saldo do jogador não pode ficar negativo'
);

select ok(
  exists(
    select 1 from pg_constraint
    where conrelid='public.ludo_rooms'::regclass
      and conname='ludo_rooms_bet_amount_check'
  ),
  'Finanças: aposta do Ludo tem mínimo no banco'
);

select ok(
  exists(
    select 1 from pg_constraint
    where conrelid='public.ludo_rooms'::regclass
      and conname='ludo_rooms_bet_whole_mzn_check'
  ),
  'Finanças: aposta do Ludo é MZN inteiro'
);

select ok(
  exists(
    select 1 from pg_constraint
    where conrelid='public.ludo_room_players'::regclass
      and conname='ludo_room_players_stake_whole_mzn_check'
  ),
  'Finanças: stake do jogador é MZN inteiro'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_refund_room(uuid,text)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%from public.ludo_rooms where id=p_room for update%',
  'Finanças: refund bloqueia a sala'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_refund_room(uuid,text)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%where room_id=p_room and stake_paid order by seat for update%',
  'Finanças: refund serializa participantes pagos'
);

select ok(
  pg_get_functiondef('public.jl_ludo_refund_room(uuid,text)'::regprocedure)
    like '%jl_reverse_cash_wager%',
  'Finanças: refund restaura requisito de dinheiro apostado'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_refund_room(uuid,text)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%set stake_paid=false,stake_amount=0%',
  'Finanças: refund marca a stake como devolvida'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_finish_room(uuid,uuid,integer)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%comm:=least(gross,greatest(1,ceil(gross*0.01)))%',
  'Finanças: comissão do Ludo mantém 1% arredondado para cima'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_finish_room(uuid,uuid,integer)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%gross:=round(r.pot/2,2)%',
  'Finanças: parceiros calculam prémio individual a partir de metade do pote'
);

select ok(
  exists(
    select 1 from pg_constraint
    where conrelid='public.ludo_payouts'::regclass
      and conname='ludo_payouts_room_id_player_id_key'
      and contype='u'
  ),
  'Finanças: payout do Ludo é único por sala/jogador'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_finish_room(uuid,uuid,integer)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%on conflict(room_id,player_id) do nothing returning id into v_payout_id%',
  'Finanças: payout reclama primeiro a referência única'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_finish_room(uuid,uuid,integer)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%if v_payout_id is not null then update public.players set balance=balance+net%',
  'Finanças: saldo só é creditado depois de reclamar o payout'
);

select ok(
  lower(regexp_replace(pg_get_functiondef('public.jl_ludo_reenter(text,uuid)'::regprocedure), E'\\s+', ' ', 'g'))
    like '%if pl.balance<amt then raise exception ''saldo insuficiente para reentrar.''%',
  'Finanças: reentrada rejeita saldo insuficiente'
);

select ok(
  pg_get_functiondef('public.jl_ludo_join_room_internal(uuid,uuid)'::regprocedure)
    like '%jl_require_cash_balance%',
  'Finanças: entrada em sala exige saldo disponível'
);

select ok(
  to_regclass('public.financial_idempotency') is not null,
  'Finanças: tabela de idempotência existe'
);

select ok(
  to_regprocedure('public.jl_request_deposit_idempotent(text,numeric,text,text)') is not null,
  'Finanças: depósito possui RPC idempotente'
);

select ok(
  to_regprocedure('public.jl_request_withdrawal_idempotent(text,numeric,text)') is not null,
  'Finanças: saque possui RPC idempotente'
);

select ok(
  to_regprocedure('public.jl_place_bet_idempotent(text,integer,numeric,text)') is not null,
  'Finanças: Número possui aposta idempotente'
);

select ok(
  to_regprocedure('public.jl_place_pair_bet_idempotent(text,integer,integer,numeric,text)') is not null,
  'Finanças: Dupla possui aposta idempotente'
);

select ok(
  exists(
    select 1 from pg_indexes
    where schemaname='public'
      and tablename='transactions'
      and indexdef ilike '%unique%'
      and indexdef ilike '%reference_id%'
      and indexdef ilike '%player_id%'
  ),
  'Finanças: transações críticas possuem referência única'
);

select ok(
  to_regclass('public.deposit_wager_requirements') is not null
  and to_regclass('public.deposit_wager_usages') is not null
  and to_regprocedure('public.jl_apply_cash_wager(uuid,numeric,text,uuid)') is not null
  and to_regprocedure('public.jl_reverse_cash_wager(uuid,text,uuid)') is not null,
  'Finanças: requisito de depósito jogado e reversão estão presentes'
);

select ok(
  exists(
    select 1 from pg_constraint
    where conrelid='public.transactions'::regclass
      and conname='transactions_amount_nonzero_ck'
  ),
  'Finanças: transação de valor zero é rejeitada'
);

select ok(
  exists(
    select 1 from pg_constraint
    where conrelid='public.ludo_payouts'::regclass
      and conname='ludo_payouts_consistent_ck'
  ),
  'Finanças: gross = comissão + líquido é invariante do banco'
);

select * from finish();
rollback;

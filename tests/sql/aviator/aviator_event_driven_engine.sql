-- Ponto 39: motor Aviator orientado a eventos, sem tick pesado por atualização visual.
begin;

do $test$
declare
  v_round bigint;
  v_started timestamptz:=clock_timestamp();
  v_due timestamptz;
  v_expected timestamptz;
  v_def text;
begin
  if not exists(
    select 1
    from information_schema.columns
    where table_schema='public'
      and table_name='jl_aviator_rounds'
      and column_name='engine_due_at'
  ) then
    raise exception 'engine_due_at ausente';
  end if;

  if not exists(
    select 1 from pg_indexes
    where schemaname='public'
      and tablename='jl_aviator_rounds'
      and indexname='jl_aviator_rounds_engine_due_idx'
  ) then
    raise exception 'índice de engine_due_at ausente';
  end if;

  if not exists(
    select 1 from pg_indexes
    where schemaname='public'
      and tablename='jl_aviator_bets'
      and indexname='jl_aviator_bets_active_auto_due_idx'
  ) then
    raise exception 'índice parcial de auto cash-out ausente';
  end if;

  select pg_get_functiondef(p.oid)
    into v_def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='jl_process_game_engine_tick';

  if position('engine_due_at<=clock_timestamp()' in replace(v_def,' ',''))=0 then
    raise exception 'engine global não usa engine_due_at';
  end if;

  if position('status=''FLYING'' and engine_due_at' in lower(v_def))>0 then
    null;
  end if;

  select pg_get_functiondef(p.oid)
    into v_def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='jl_aviator_tick';

  if position('jl_aviator_schedule_next_engine_event' in v_def)=0 then
    raise exception 'tick não reagenda próximo evento';
  end if;

  select pg_get_functiondef(p.oid)
    into v_def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='jl_aviator_cashout_locked';

  if position('p_source=''MANUAL''' in v_def)=0
     or position('jl_aviator_schedule_next_engine_event' in v_def)=0 then
    raise exception 'cash-out manual não reagenda motor';
  end if;

  insert into public.jl_aviator_rounds(
    status,started_at,financial_ceiling,effective_target,visual_target
  )
  values('FLYING',v_started,2.00,2.00,2.00)
  returning id into v_round;

  v_due:=public.jl_aviator_schedule_next_engine_event(v_round);
  v_expected:=public.jl_aviator_multiplier_reach_at(v_started,2.00);

  if abs(extract(epoch from (v_due-v_expected)))>0.001 then
    raise exception 'próximo evento não corresponde ao alvo matemático';
  end if;

  if v_due<=v_started then
    raise exception 'próximo evento deveria estar no futuro';
  end if;

  if has_function_privilege(
       'anon',
       'public.jl_aviator_schedule_next_engine_event(bigint)',
       'EXECUTE'
     )
     or has_function_privilege(
       'authenticated',
       'public.jl_aviator_schedule_next_engine_event(bigint)',
       'EXECUTE'
     ) then
    raise exception 'scheduler interno exposto ao cliente';
  end if;

  if not has_function_privilege(
       'anon',
       'public.jl_aviator_bet_status(text,bigint)',
       'EXECUTE'
     ) then
    raise exception 'RPC leve de status da aposta indisponível';
  end if;

  select pg_get_functiondef(p.oid)
    into v_def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='jl_aviator_bet_status';

  if position('jl_player_ledger_balance' in v_def)>0
     or position('jsonb_agg' in v_def)>0
     or position('limit 20' in lower(v_def))>0 then
    raise exception 'RPC leve voltou a consultar ledger/histórico';
  end if;
end
$test$;

rollback;

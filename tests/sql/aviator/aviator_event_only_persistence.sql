-- Ponto 40: persistir eventos importantes, nunca frames/ticks visuais do multiplicador.
begin;

do $test$
declare
  v_def text;
  v_blocked boolean:=false;
begin
  if exists(
    select 1
    from information_schema.columns
    where table_schema='public'
      and table_name like 'jl_aviator%'
      and column_name in (
        'current_multiplier',
        'frame_multiplier',
        'live_multiplier',
        'visual_frame',
        'tick_multiplier'
      )
  ) then
    raise exception 'Foi criado campo persistente de frame/multiplicador vivo';
  end if;

  if exists(
    select 1
    from pg_tables
    where schemaname='public'
      and tablename ~* 'aviator.*(frame|tick|multiplier.*history|visual.*history)'
  ) then
    raise exception 'Foi criada tabela de histórico visual/ticks do Aviator';
  end if;

  if not exists(
    select 1
    from pg_constraint
    where conrelid='public.audit_log'::regclass
      and conname='audit_log_no_aviator_visual_noise'
  ) then
    raise exception 'Constraint anti-ruído visual ausente';
  end if;

  begin
    insert into public.audit_log(action,details)
    values('aviator.frame','{}'::jsonb);
  exception
    when check_violation then
      v_blocked:=true;
  end;

  if not v_blocked then
    raise exception 'audit_log aceitou frame visual do Aviator';
  end if;

  if exists(
    select 1
    from public.audit_log
    where action ~* '^aviator\.(frame|tick|render|heartbeat|multiplier_frame|multiplier_update|visual_frame)([._]|$)'
  ) then
    raise exception 'audit_log contém ruído visual/tick do Aviator';
  end if;

  select pg_get_functiondef(p.oid)
  into v_def
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='jl_aviator_schedule_next_engine_event';

  if position('engine_due_at is distinct from v_due' in lower(v_def))=0 then
    raise exception 'scheduler voltou a gravar engine_due_at sem mudança';
  end if;

  select pg_get_functiondef(p.oid)
  into v_def
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='jl_cron_prune_history';

  if position('interval ''2 hours''' in lower(v_def))=0
     or position('interval ''30 days''' in lower(v_def))=0 then
    raise exception 'retenção de cron não preserva política curta de sucesso/longa de falha';
  end if;
end
$test$;

rollback;

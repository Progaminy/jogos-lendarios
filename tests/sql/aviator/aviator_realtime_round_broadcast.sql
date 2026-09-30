-- Ponto 35: Realtime/Broadcast para estado público da rodada Aviator.
begin;

do $test$
declare
  v_def text;
  v_public jsonb;
begin
  if to_regprocedure('public.jl_aviator_realtime_broadcast_state()') is null then
    raise exception 'função de broadcast Aviator ausente';
  end if;

  select pg_get_functiondef(p.oid)
  into v_def
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='jl_aviator_realtime_broadcast_state';

  if position('realtime.send' in v_def)=0
     or position('jl_aviator_public_state' in v_def)=0
     or position('aviator:round' in v_def)=0 then
    raise exception 'broadcast não usa estado público canónico';
  end if;

  if position('NEW.' in v_def)>0 or position('OLD.' in v_def)>0 then
    raise exception 'broadcast não deve serializar a linha interna da rodada';
  end if;

  if not exists(
    select 1
    from pg_trigger t
    join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relname='jl_aviator_rounds'
      and t.tgname='jl_aviator_round_realtime_state'
      and not t.tgisinternal
  ) then
    raise exception 'trigger Realtime da rodada ausente';
  end if;

  if not exists(
    select 1
    from pg_trigger t
    join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relname='jl_aviator_settings'
      and t.tgname='jl_aviator_settings_realtime_state'
      and not t.tgisinternal
  ) then
    raise exception 'trigger Realtime das configurações ausente';
  end if;

  v_public:=public.jl_aviator_public_state();

  if (v_public->'round') ? 'bank_balance_snapshot'
     or (v_public->'round') ? 'risk_reserve'
     or (v_public->'round') ? 'financial_ceiling'
     or (v_public->'round') ? 'effective_target'
     or (v_public->'round') ? 'visual_target'
     or (v_public->'round') ? 'admin_cancel_reason'
     or (v_public->'round') ? 'admin_cancelled_by' then
    raise exception 'estado público contém campo financeiro/administrativo sensível';
  end if;

  if has_function_privilege(
       'anon',
       'public.jl_aviator_realtime_broadcast_state()',
       'EXECUTE'
     )
     or has_function_privilege(
       'authenticated',
       'public.jl_aviator_realtime_broadcast_state()',
       'EXECUTE'
     ) then
    raise exception 'função interna de broadcast exposta ao cliente';
  end if;
end
$test$;

rollback;

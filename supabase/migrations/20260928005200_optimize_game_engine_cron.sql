-- Ponto 10 — reduzir trabalho e crescimento de histórico do cron.
-- Mantém draw_at como fonte de verdade e não altera regras de sorteio/pagamento.
-- O cron passa a executar um tick leve a cada 2s e só roda o motor completo
-- quando existe transição realmente necessária.
-- Histórico de sucesso: 48h. Falhas: 30 dias.

create or replace function public.jl_process_game_engine_tick()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_need_work boolean:=false;
begin
  select exists(
    select 1
    from public.game_rounds
    where status in ('open','locked','closed')
      and (
        (status='open' and closes_at<=now())
        or draw_at<=now()
      )
  )
  or exists(
    select 1
    from public.draw_schedule ds
    join public.game_settings gs
      on gs.game_type=ds.game_type
     and gs.enabled
    where ds.status='pending'
      and not exists(
        select 1
        from public.game_rounds gr
        where gr.game_type=ds.game_type
          and gr.status in ('open','locked','closed','drawn')
      )
  )
  into v_need_work;

  if not v_need_work then
    return jsonb_build_object('idle',true,'processed_at',now());
  end if;

  return public.jl_process_game_engine();
end;
$function$;

revoke all on function public.jl_process_game_engine_tick()
from public,anon,authenticated;
grant execute on function public.jl_process_game_engine_tick()
to service_role;

create or replace function public.jl_cron_prune_history()
returns integer
language plpgsql
security definer
set search_path to 'cron','public'
as $function$
declare
  v_deleted integer:=0;
begin
  delete from cron.job_run_details
  where
    (status='succeeded' and coalesce(end_time,start_time)<now()-interval '48 hours')
    or
    (coalesce(status,'')<>'succeeded' and start_time<now()-interval '30 days');

  get diagnostics v_deleted=row_count;
  return v_deleted;
end;
$function$;

revoke all on function public.jl_cron_prune_history()
from public,anon,authenticated;
grant execute on function public.jl_cron_prune_history()
to service_role;

select cron.alter_job(
  2,
  schedule=>'2 seconds',
  command=>'select public.jl_process_game_engine_tick();',
  active=>true
);

do $$
declare
  v_job bigint;
begin
  select jobid into v_job
  from cron.job
  where jobname='jogos_lendarios_cron_history_cleanup'
  limit 1;

  if v_job is not null then
    perform cron.unschedule(v_job);
  end if;
end
$$;

select cron.schedule(
  'jogos_lendarios_cron_history_cleanup',
  '17 * * * *',
  'select public.jl_cron_prune_history();'
);

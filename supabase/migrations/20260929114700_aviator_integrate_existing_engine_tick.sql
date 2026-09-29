-- Integrar Aviator no cron global existente (2s), sem criar novo job.
create or replace function public.jl_process_game_engine_tick()
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_need_work boolean:=false; v_aviator_need boolean:=false; v_main jsonb; v_aviator jsonb;
begin
 select exists(select 1 from public.game_rounds where status in ('open','locked','closed') and ((status='open' and closes_at<=now()) or draw_at<=now()))
 or exists(select 1 from public.draw_schedule ds join public.game_settings gs on gs.game_type=ds.game_type and gs.enabled where ds.status='pending' and not exists(select 1 from public.game_rounds gr where gr.game_type=ds.game_type and gr.status in ('open','locked','closed','drawn'))) into v_need_work;
 select exists(select 1 from public.jl_aviator_rounds where (status='OPEN' and betting_closes_at<=now()) or status='FLYING' or (status='SETTLED' and coalesce(next_round_at,now())<=now()))
 or not exists(select 1 from public.jl_aviator_rounds) into v_aviator_need;
 if v_need_work then v_main:=public.jl_process_game_engine(); else v_main:=jsonb_build_object('idle',true); end if;
 if v_aviator_need then v_aviator:=public.jl_aviator_engine_tick(); else v_aviator:=jsonb_build_object('idle',true); end if;
 return jsonb_build_object('main',v_main,'aviator',v_aviator,'processed_at',now());
end $$;
revoke all on function public.jl_process_game_engine_tick() from public,anon,authenticated;
grant execute on function public.jl_process_game_engine_tick() to service_role;
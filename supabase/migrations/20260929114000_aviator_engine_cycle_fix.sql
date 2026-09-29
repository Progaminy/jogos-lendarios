-- Aviator: respeitar a pausa entre rodadas; engine nao abre rodada fora do horario.
create or replace function public.jl_aviator_engine_tick()
returns jsonb language plpgsql security definer set search_path=public
as $$
declare r public.jl_aviator_rounds; result jsonb;
begin
 perform pg_advisory_xact_lock(hashtext('jl_aviator_engine_tick'));
 select * into r from public.jl_aviator_rounds where status in ('OPEN','LOCKED','FLYING') order by id desc limit 1 for update;
 if r.id is null then return public.jl_aviator_open_next_if_due(); end if;
 if r.status='OPEN' and r.betting_closes_at is not null and now()>=r.betting_closes_at then
   perform public.jl_aviator_lock_round(r.id);
   update public.jl_aviator_rounds set status='FLYING',started_at=clock_timestamp() where id=r.id;
   return jsonb_build_object('action','STARTED','round_id',r.id);
 end if;
 if r.status='FLYING' then
   result:=public.jl_aviator_tick(r.id);
   if result->>'status'='CRASHED' then
     perform public.jl_aviator_publish_proof(r.id);
     update public.jl_aviator_rounds set status='SETTLED',settled_at=now(),next_round_at=now()+interval '4 seconds' where id=r.id;
   end if;
   return result;
 end if;
 return jsonb_build_object('action','WAIT','round_id',r.id,'status',r.status);
end $$;

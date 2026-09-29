-- Aviator Lendario: ciclo automatico/public state.
alter table public.jl_aviator_rounds
  add column if not exists betting_closes_at timestamptz,
  add column if not exists next_round_at timestamptz;

create unique index if not exists jl_aviator_one_live_round_idx
on public.jl_aviator_rounds ((1))
where status in ('OPEN','LOCKED','FLYING');

create or replace function public.jl_aviator_public_state()
returns jsonb language plpgsql security definer set search_path=public
as $$
declare r public.jl_aviator_rounds; v_active int; v_total numeric;
begin
 select * into r from public.jl_aviator_rounds order by id desc limit 1;
 if r.id is null then return jsonb_build_object('server_time',now(),'round',null); end if;
 select count(*),coalesce(sum(stake),0) into v_active,v_total from public.jl_aviator_bets where round_id=r.id and status='ACTIVE';
 return jsonb_build_object('server_time',now(),'round',jsonb_build_object(
   'id',r.id,'status',r.status,'opened_at',r.opened_at,'betting_closes_at',r.betting_closes_at,
   'started_at',r.started_at,'crashed_at',r.crashed_at,'crash_multiplier',r.crash_multiplier,
   'active_bets',v_active,'total_staked',v_total,'visual_extension',r.visual_extension,
   'visual_seed_commit',r.visual_seed_commit,
   'visual_seed_reveal',case when r.status in ('CRASHED','SETTLED') then r.visual_seed_reveal else null end
 ));
end $$;

create or replace function public.jl_aviator_engine_tick()
returns jsonb language plpgsql security definer set search_path=public
as $$
declare r public.jl_aviator_rounds; result jsonb;
begin
 perform pg_advisory_xact_lock(hashtext('jl_aviator_engine_tick'));
 select * into r from public.jl_aviator_rounds where status in ('OPEN','LOCKED','FLYING') order by id desc limit 1 for update;

 if r.id is null then
   insert into public.jl_aviator_rounds(status,betting_closes_at) values('OPEN',now()+interval '12 seconds') returning * into r;
   return jsonb_build_object('action','OPENED','round_id',r.id);
 end if;

 if r.status='OPEN' and r.betting_closes_at is not null and now()>=r.betting_closes_at then
   perform public.jl_aviator_lock_round(r.id);
   update public.jl_aviator_rounds set status='FLYING',started_at=clock_timestamp() where id=r.id;
   return jsonb_build_object('action','STARTED','round_id',r.id);
 end if;

 if r.status='FLYING' then
   result:=public.jl_aviator_tick(r.id);
   if result->>'status'='CRASHED' then
     update public.jl_aviator_rounds set status='SETTLED',settled_at=now(),next_round_at=now()+interval '4 seconds' where id=r.id;
   end if;
   return result;
 end if;
 return jsonb_build_object('action','WAIT','round_id',r.id,'status',r.status);
end $$;

create or replace function public.jl_aviator_open_next_if_due()
returns jsonb language plpgsql security definer set search_path=public
as $$
declare r public.jl_aviator_rounds;
begin
 perform pg_advisory_xact_lock(hashtext('jl_aviator_engine_tick'));
 if exists(select 1 from public.jl_aviator_rounds where status in ('OPEN','LOCKED','FLYING')) then return jsonb_build_object('opened',false); end if;
 select * into r from public.jl_aviator_rounds order by id desc limit 1;
 if r.id is null or (r.status='SETTLED' and coalesce(r.next_round_at,now())<=now()) then
   insert into public.jl_aviator_rounds(status,betting_closes_at) values('OPEN',now()+interval '12 seconds') returning * into r;
   return jsonb_build_object('opened',true,'round_id',r.id);
 end if;
 return jsonb_build_object('opened',false);
end $$;

revoke all on function public.jl_aviator_public_state() from public;
grant execute on function public.jl_aviator_public_state() to anon,authenticated;
revoke all on function public.jl_aviator_engine_tick() from public,anon,authenticated;
revoke all on function public.jl_aviator_open_next_if_due() from public,anon,authenticated;
grant execute on function public.jl_aviator_engine_tick() to service_role;
grant execute on function public.jl_aviator_open_next_if_due() to service_role;

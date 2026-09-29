-- Aviator: idempotencia de crash e protecao de liquidacao concorrente.
alter table public.jl_aviator_rounds add column if not exists lost_stakes_credited boolean not null default false;

create or replace function public.jl_aviator_tick(p_round_id bigint)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v public.jl_aviator_rounds; v_m numeric; v_lost numeric:=0;
begin
 perform pg_advisory_xact_lock(hashtext('jl_aviator_round_'||p_round_id::text));
 select * into v from public.jl_aviator_rounds where id=p_round_id for update;
 if v.id is null then raise exception 'Rodada nao encontrada'; end if;
 if v.status<>'FLYING' then return jsonb_build_object('status',v.status,'round_id',v.id,'crash_multiplier',v.crash_multiplier); end if;
 v_m:=public.jl_aviator_multiplier(v.started_at,clock_timestamp());
 if v_m<coalesce(v.effective_target,v.financial_ceiling,v.visual_target) then return jsonb_build_object('status','FLYING','round_id',v.id,'multiplier',v_m); end if;

 update public.jl_aviator_bets set status='LOST',payout=0 where round_id=v.id and status='ACTIVE';
 if not v.lost_stakes_credited then
   select coalesce(sum(stake),0) into v_lost from public.jl_aviator_bets where round_id=v.id and status='LOST';
   update public.jl_aviator_bank set balance=round(balance+v_lost,2),updated_at=now() where id=true;
 end if;
 update public.jl_aviator_rounds set status='CRASHED',crashed_at=clock_timestamp(),
   crash_multiplier=coalesce(effective_target,financial_ceiling,visual_target),lost_stakes_credited=true
 where id=v.id returning * into v;
 insert into public.audit_log(action,details) values('aviator.crashed',jsonb_build_object('roundId',v.id,'crashMultiplier',v.crash_multiplier,'lostStakes',v_lost,'visualExtension',v.visual_extension));
 return jsonb_build_object('status','CRASHED','round_id',v.id,'crash_multiplier',v.crash_multiplier);
end $$;

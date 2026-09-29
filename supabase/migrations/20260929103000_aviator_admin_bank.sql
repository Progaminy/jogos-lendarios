-- Aviator: administracao segura da banca e painel.
create table if not exists public.jl_aviator_bank_ledger(
 id bigint generated always as identity primary key,
 delta numeric(18,2) not null,
 balance_after numeric(18,2) not null,
 reason text not null,
 created_at timestamptz not null default now()
);
alter table public.jl_aviator_bank_ledger enable row level security;
revoke all on public.jl_aviator_bank_ledger from anon,authenticated;

create or replace function public.jl_aviator_admin_state(p_token text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare b public.jl_aviator_bank; r public.jl_aviator_rounds; v_active int; v_staked numeric; v_paid numeric;
begin
 perform public.jl_require_admin(p_token);
 select * into b from public.jl_aviator_bank where id=true;
 select * into r from public.jl_aviator_rounds order by id desc limit 1;
 select count(*),coalesce(sum(stake),0),coalesce(sum(payout),0) into v_active,v_staked,v_paid
 from public.jl_aviator_bets where round_id=r.id;
 return jsonb_build_object('bank',jsonb_build_object('balance',b.balance,'exposure_ratio',b.exposure_ratio),
 'round',case when r.id is null then null else jsonb_build_object('id',r.id,'status',r.status,'total_staked',r.total_staked,
 'risk_reserve',r.risk_reserve,'financial_ceiling',r.financial_ceiling,'crash_multiplier',r.crash_multiplier,
 'visual_extension',r.visual_extension,'opened_at',r.opened_at,'started_at',r.started_at) end,
 'bets',v_active,'stake_sum',v_staked,'paid_sum',v_paid);
end $$;

create or replace function public.jl_aviator_admin_adjust_bank(p_token text,p_delta numeric,p_reason text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare b public.jl_aviator_bank;
begin
 perform public.jl_require_admin(p_token);
 if p_delta is null or p_delta=0 or abs(p_delta)>100000000 then raise exception 'Ajuste invalido'; end if;
 if length(trim(coalesce(p_reason,'')))<3 then raise exception 'Informe o motivo'; end if;
 select * into b from public.jl_aviator_bank where id=true for update;
 if b.balance+p_delta<0 then raise exception 'Ajuste deixaria a banca negativa'; end if;
 update public.jl_aviator_bank set balance=round(balance+p_delta,2),updated_at=now() where id=true returning * into b;
 insert into public.jl_aviator_bank_ledger(delta,balance_after,reason) values(round(p_delta,2),b.balance,left(trim(p_reason),160));
 insert into public.audit_log(action,details) values('aviator.bank_adjusted',jsonb_build_object('delta',round(p_delta,2),'balance',b.balance,'reason',left(trim(p_reason),160)));
 return jsonb_build_object('ok',true,'balance',b.balance);
end $$;

revoke all on function public.jl_aviator_admin_state(text) from public;
revoke all on function public.jl_aviator_admin_adjust_bank(text,numeric,text) from public;
grant execute on function public.jl_aviator_admin_state(text) to anon,authenticated;
grant execute on function public.jl_aviator_admin_adjust_bank(text,numeric,text) to anon,authenticated;

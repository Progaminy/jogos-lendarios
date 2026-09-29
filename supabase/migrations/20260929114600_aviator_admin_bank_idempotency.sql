-- Aviator: ajustes administrativos idempotentes e reserva protegida durante voo.
alter table public.jl_aviator_bank_ledger add column if not exists request_key text;
create unique index if not exists jl_aviator_bank_ledger_request_key_uidx on public.jl_aviator_bank_ledger(request_key) where request_key is not null;
create or replace function public.jl_aviator_admin_adjust_bank(p_token text,p_delta numeric,p_reason text,p_request_key text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare b public.jl_aviator_bank; l public.jl_aviator_bank_ledger;
begin
 perform public.jl_require_admin(p_token);
 if p_request_key is null or length(trim(p_request_key))<8 or length(p_request_key)>100 then raise exception 'Chave do ajuste invalida'; end if;
 select * into l from public.jl_aviator_bank_ledger where request_key=p_request_key;
 if l.id is not null then return jsonb_build_object('ok',true,'already_processed',true,'balance',l.balance_after); end if;
 if p_delta is null or p_delta=0 or abs(p_delta)>100000000 then raise exception 'Ajuste invalido'; end if;
 if length(trim(coalesce(p_reason,'')))<3 then raise exception 'Informe o motivo'; end if;
 perform pg_advisory_xact_lock(hashtext('jl_aviator_bank_adjust'));
 if p_delta<0 and exists(select 1 from public.jl_aviator_rounds where status in ('LOCKED','FLYING')) then raise exception 'Nao e permitido retirar fundos da banca durante exposicao financeira ativa'; end if;
 select * into b from public.jl_aviator_bank where id=true for update;
 if b.balance+p_delta<0 then raise exception 'Ajuste deixaria a banca negativa'; end if;
 update public.jl_aviator_bank set balance=round(balance+p_delta,2),updated_at=now() where id=true returning * into b;
 insert into public.jl_aviator_bank_ledger(delta,balance_after,reason,request_key) values(round(p_delta,2),b.balance,left(trim(p_reason),160),p_request_key);
 insert into public.audit_log(action,details) values('aviator.bank_adjusted',jsonb_build_object('delta',round(p_delta,2),'balance',b.balance,'reason',left(trim(p_reason),160),'requestKey',p_request_key));
 return jsonb_build_object('ok',true,'already_processed',false,'balance',b.balance);
end $$;
revoke execute on function public.jl_aviator_admin_adjust_bank(text,numeric,text) from public,anon,authenticated;
grant execute on function public.jl_aviator_admin_adjust_bank(text,numeric,text,text) to anon,authenticated;
alter table public.transactions drop constraint if exists transactions_kind_check;
alter table public.transactions add constraint transactions_kind_check check (
  kind = any (array[
    'deposit'::text,'withdrawal'::text,'withdrawal_refund'::text,'bet'::text,'payout'::text,'adjustment'::text,
    'ludo_stake'::text,'ludo_reentry'::text,'ludo_refund'::text,'ludo_payout'::text,
    'aviator_bet'::text,'aviator_payout'::text,'aviator_refund'::text,
    'dama_stake'::text,'dama_refund'::text,'dama_payout'::text,
    'free_access_payment'::text,'free_access_refund'::text
  ])
);

create or replace function public.jl_free_access_request(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare me uuid:=public.jl_player_id(p_token); s public.free_access_settings%rowtype; rid uuid:=extensions.gen_random_uuid(); ledger_balance numeric; wallet_balance numeric;
begin
  select * into s from public.free_access_settings where id=1 for update;
  if not coalesce(s.enabled,false) then raise exception 'FREE indisponível.'; end if;
  if public.jl_free_access_active(me) then return public.jl_free_access_status(p_token); end if;
  if exists(select 1 from public.free_access_requests where player_id=me and status='pending') then return public.jl_free_access_status(p_token); end if;
  if s.price>0 then
    perform public.jl_lock_player_wallet(me);
    ledger_balance:=public.jl_player_ledger_balance(me);
    select balance into wallet_balance from public.players where id=me for update;
    if coalesce(ledger_balance,0)<s.price or coalesce(wallet_balance,0)<s.price then raise exception 'Saldo insuficiente.'; end if;
  end if;
  insert into public.free_access_requests(id,player_id,amount,status) values(rid,me,s.price,'pending');
  if s.price>0 then
    update public.players set balance=round(balance-s.price,2),updated_at=now() where id=me;
    insert into public.transactions(player_id,kind,amount,status,reference_id,note)
    values(me,'free_access_payment',-s.price,'completed',rid,'FREE · pagamento pendente de aprovação');
  end if;
  return public.jl_free_access_status(p_token);
end; $$;

create or replace function public.jl_admin_free_access_review(p_token text,p_request_id uuid,p_decision text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare req public.free_access_requests%rowtype; admin_id uuid;
begin
  perform public.jl_require_admin_elevated(p_token);
  admin_id:=public.jl_admin_account_id(p_token);
  if p_decision not in ('approved','rejected') then raise exception 'Decisão inválida.'; end if;
  select * into req from public.free_access_requests where id=p_request_id for update;
  if req.id is null or req.status<>'pending' then raise exception 'Pedido indisponível.'; end if;
  update public.free_access_requests set status=p_decision,reviewed_at=now(),reviewed_by=admin_id where id=req.id;
  if p_decision='approved' then
    insert into public.free_access_memberships(player_id,active,amount_paid,request_id,activated_at,updated_at)
    values(req.player_id,true,req.amount,req.id,now(),now())
    on conflict(player_id) do update set active=true,amount_paid=excluded.amount_paid,request_id=excluded.request_id,activated_at=now(),updated_at=now();
  elsif req.amount>0 then
    perform public.jl_lock_player_wallet(req.player_id);
    update public.players set balance=round(balance+req.amount,2),updated_at=now() where id=req.player_id;
    insert into public.transactions(player_id,kind,amount,status,reference_id,note)
    values(req.player_id,'free_access_refund',req.amount,'completed',req.id,'FREE · pagamento devolvido');
    update public.free_access_requests set refunded_at=now() where id=req.id;
  end if;
  return public.jl_admin_free_access_overview(p_token);
end; $$;

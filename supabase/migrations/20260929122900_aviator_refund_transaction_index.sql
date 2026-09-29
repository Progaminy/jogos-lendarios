-- Cobertura da FK de reembolso e garantia de vínculo 1:1 transação/aposta.
create unique index if not exists jl_aviator_bets_refund_transaction_uidx
on public.jl_aviator_bets(refund_transaction_id)
where refund_transaction_id is not null;

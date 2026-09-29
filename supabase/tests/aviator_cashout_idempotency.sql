-- Executar apos migrations. Guardas estruturais para dinheiro real.
begin;
do $$ begin
 if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='jl_aviator_bets' and column_name='payout_transaction_id') then raise exception 'payout_transaction_id ausente'; end if;
 if not exists(select 1 from pg_indexes where schemaname='public' and indexname='jl_aviator_bets_payout_tx_unique') then raise exception 'indice idempotente ausente'; end if;
 if public.jl_aviator_financial_ceiling(100000,200000,.5)<>1.25 then raise exception 'regra financeira mudou'; end if;
end $$;
rollback;
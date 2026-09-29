-- Aviator: estado do cliente apenas por RPC; sem leitura direta das tabelas.
revoke select on public.jl_aviator_rounds from anon,authenticated;
revoke select on public.jl_aviator_bets from anon,authenticated;
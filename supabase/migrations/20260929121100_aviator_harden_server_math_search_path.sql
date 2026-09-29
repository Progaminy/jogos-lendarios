-- Aviator: fixa search_path dos helpers matematicos internos.
-- Nao altera formulas, apenas remove dependencia de search_path da sessao.

alter function public.jl_aviator_multiplier(timestamptz,timestamptz)
  set search_path = pg_catalog, public;

alter function public.jl_aviator_financial_ceiling(numeric,numeric,numeric)
  set search_path = pg_catalog, public;

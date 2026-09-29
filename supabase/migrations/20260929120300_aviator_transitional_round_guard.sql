-- Aviator: garantir uma unica rodada transitoria, incluindo CRASHED,
-- e dar ao motor um indice minimo independente do tamanho do historico.

create unique index if not exists jl_aviator_one_transitional_round_idx
  on public.jl_aviator_rounds ((1))
  where status in ('OPEN','LOCKED','FLYING','CRASHED');

create index if not exists jl_aviator_rounds_transitional_id_idx
  on public.jl_aviator_rounds (id desc)
  where status in ('OPEN','LOCKED','FLYING','CRASHED');

-- Testes matematicos do teto financeiro do Aviator Lendario.
begin;
do $$
begin
  if public.jl_aviator_financial_ceiling(200000,100000,0.5) <> 2 then
    raise exception 'Esperado 2x para banca 200k / apostas 100k';
  end if;
  if public.jl_aviator_financial_ceiling(100000,100000,0.5) <> 1.5 then
    raise exception 'Esperado 1.5x para banca 100k / apostas 100k';
  end if;
  if public.jl_aviator_financial_ceiling(100000,200000,0.5) <> 1.25 then
    raise exception 'Esperado 1.25x para banca 100k / apostas 200k';
  end if;
  if public.jl_aviator_financial_ceiling(200000,100000,0.5) <> public.jl_aviator_financial_ceiling(200000,100000,0.5) then
    raise exception 'Teto deve ser deterministico';
  end if;
end $$;
rollback;

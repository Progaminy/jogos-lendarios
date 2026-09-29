begin;
do $$
declare s timestamptz:=now()-interval '10 seconds'; m numeric;
begin
 m:=public.jl_aviator_multiplier(s,s+interval '10 seconds');
 if m<=1 then raise exception 'Multiplicador deve crescer'; end if;
 if public.jl_aviator_financial_ceiling(200000,100000,0.5)<>2 then raise exception '2x falhou'; end if;
 if public.jl_aviator_financial_ceiling(100000,100000,0.5)<>1.5 then raise exception '1.5x falhou'; end if;
end $$;
rollback;

begin;
do $$
declare r public.jl_aviator_rounds;
begin
 if (select count(*) from pg_indexes where indexname='jl_aviator_one_live_round_idx')<>1 then raise exception 'indice de rodada unica ausente'; end if;
 if public.jl_aviator_financial_ceiling(200000,100000,.5)<>2 then raise exception 'teto alterado'; end if;
end $$;
rollback;
-- Aviator: teste estrutural das garantias financeiras e de reconexao.
do $$
begin
 if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='jl_aviator_bets' and column_name='request_key') then raise exception 'request_key ausente'; end if;
 if not exists(select 1 from pg_proc where proname='jl_aviator_player_state') then raise exception 'player_state ausente'; end if;
 if not exists(select 1 from pg_proc where proname='jl_aviator_publish_proof') then raise exception 'publish_proof ausente'; end if;
 if not exists(select 1 from pg_class where relname='jl_aviator_round_secrets') then raise exception 'round_secrets ausente'; end if;
 if public.jl_aviator_financial_ceiling(200000,100000,.5)<>2 then raise exception 'teto 2x falhou'; end if;
 if public.jl_aviator_financial_ceiling(100000,100000,.5)<>1.5 then raise exception 'teto 1.5x falhou'; end if;
 if public.jl_aviator_financial_ceiling(100000,200000,.5)<>1.25 then raise exception 'teto 1.25x falhou'; end if;
 if public.jl_aviator_financial_ceiling(100000,0,.5) is not null then raise exception 'A=0 deve ser visual'; end if;
end $$;

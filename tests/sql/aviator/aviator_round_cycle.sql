begin; do $$ begin
 if public.jl_aviator_multiplier('2026-01-01 00:00:00+00','2026-01-01 00:00:00+00')<>1 then raise exception 'inicio deve ser 1x'; end if;
 if public.jl_aviator_multiplier('2026-01-01 00:00:00+00','2026-01-01 00:00:10+00')<=1 then raise exception 'voo deve crescer'; end if;
end $$; rollback;
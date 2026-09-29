-- Aviator: cash-out e crash usam a mesma trava da rodada e a mesma ordem de locks.
create or replace function public.jl_aviator_cashout_guard(p_token text,p_bet_id bigint)
returns bigint language plpgsql security definer set search_path=public
as $$
declare v_player uuid:=public.jl_player_id(p_token); v_round_id bigint;
begin
 select round_id into v_round_id from public.jl_aviator_bets where id=p_bet_id and player_id=v_player;
 if v_round_id is null then raise exception 'Aposta nao encontrada.'; end if;
 perform pg_advisory_xact_lock(hashtext('jl_aviator_round_'||v_round_id::text));
 perform 1 from public.jl_aviator_rounds where id=v_round_id for update;
 perform 1 from public.jl_aviator_bets where id=p_bet_id for update;
 return v_round_id;
end $$;

-- Aviator: estado privado do jogador para recuperar apostas depois de reconectar.
create or replace function public.jl_aviator_player_state(p_token text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_player uuid:=public.jl_player_id(p_token); v_balance numeric; v_bets jsonb;
begin
 select balance into v_balance from public.players where id=v_player;
 select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'round_id',b.round_id,'stake',b.stake,'status',b.status,'cashout_multiplier',b.cashout_multiplier,'payout',b.payout) order by b.id),'[]'::jsonb)
 into v_bets from public.jl_aviator_bets b
 join public.jl_aviator_rounds r on r.id=b.round_id
 where b.player_id=v_player and r.status in ('OPEN','LOCKED','FLYING','CRASHED','SETTLED')
 and b.created_at>now()-interval '1 day';
 return jsonb_build_object('balance',v_balance,'bets',v_bets);
end $$;
grant execute on function public.jl_aviator_player_state(text) to anon,authenticated;

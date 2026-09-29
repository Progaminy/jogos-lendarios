-- Aviator: limitar o estado privado do jogador para manter custo previsivel.
-- Mantem o mesmo formato da API, mas devolve no maximo as 20 apostas recentes
-- relevantes, usando o indice player_id/created_at existente.

create or replace function public.jl_aviator_player_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_player uuid:=public.jl_player_id(p_token);
  v_balance numeric;
  v_bets jsonb;
begin
  select balance
    into v_balance
  from public.players
  where id=v_player;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',q.id,
        'round_id',q.round_id,
        'stake',q.stake,
        'status',q.status,
        'cashout_multiplier',q.cashout_multiplier,
        'payout',q.payout
      )
      order by q.id
    ),
    '[]'::jsonb
  )
  into v_bets
  from (
    select
      b.id,
      b.round_id,
      b.stake,
      b.status,
      b.cashout_multiplier,
      b.payout
    from public.jl_aviator_bets b
    join public.jl_aviator_rounds r
      on r.id=b.round_id
    where b.player_id=v_player
      and r.status in ('OPEN','LOCKED','FLYING','CRASHED','SETTLED')
      and b.created_at>now()-interval '1 day'
    order by b.id desc
    limit 20
  ) q;

  return jsonb_build_object(
    'balance',v_balance,
    'bets',v_bets
  );
end
$$;

revoke all on function public.jl_aviator_player_state(text) from public;
grant execute on function public.jl_aviator_player_state(text) to anon,authenticated;


create or replace function public.jl_aviator_bet_status(
  p_token text,
  p_bet_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_player uuid:=public.jl_player_id(p_token);
  v_bet record;
begin
  perform public.jl_rate_limit_enforce(
    'aviator_bet_status',
    v_player::text,
    10,10,60,60
  );

  select
    b.id,
    b.bet_uid,
    b.round_id,
    r.round_no,
    b.stake,
    b.status,
    b.auto_cashout_multiplier,
    b.cashout_multiplier,
    b.cashout_source,
    b.payout,
    b.cashed_out_at,
    b.payout_transaction_id,
    b.refunded_at,
    b.refund_transaction_id
  into v_bet
  from public.jl_aviator_bets b
  join public.jl_aviator_rounds r on r.id=b.round_id
  where b.id=p_bet_id
    and b.player_id=v_player;

  if v_bet.id is null then
    return jsonb_build_object(
      'ok',false,
      'error_code','BET_NOT_FOUND'
    );
  end if;

  return jsonb_build_object(
    'ok',true,
    'bet',jsonb_build_object(
      'id',v_bet.id,
      'bet_uid',v_bet.bet_uid,
      'round_id',v_bet.round_id,
      'round_no',v_bet.round_no,
      'stake',v_bet.stake,
      'status',v_bet.status,
      'auto_cashout_multiplier',v_bet.auto_cashout_multiplier,
      'cashout_multiplier',v_bet.cashout_multiplier,
      'cashout_source',v_bet.cashout_source,
      'payout',v_bet.payout,
      'cashed_out_at',v_bet.cashed_out_at,
      'payout_transaction_id',v_bet.payout_transaction_id,
      'refunded_at',v_bet.refunded_at,
      'refund_transaction_id',v_bet.refund_transaction_id
    )
  );
end;
$function$;

revoke all on function public.jl_aviator_bet_status(text,bigint)
from public;

grant execute on function public.jl_aviator_bet_status(text,bigint)
to anon,authenticated,service_role;

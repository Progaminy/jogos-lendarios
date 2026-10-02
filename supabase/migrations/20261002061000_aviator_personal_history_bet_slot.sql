-- Aviator: histórico pessoal distingue os dois painéis de aposta.
create or replace function public.jl_aviator_my_history(
  p_token text,
  p_limit integer default 20,
  p_before_id bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_player uuid:=public.jl_player_id(p_token);
  v_limit integer:=least(50,greatest(1,coalesce(p_limit,20)));
  v_bets jsonb:='[]'::jsonb;
  v_next_before_id bigint;
  v_has_more boolean:=false;
begin
  perform public.jl_rate_limit_enforce(
    'aviator_my_history',
    v_player::text,
    8,10,60,60
  );

  with selected as (
    select
      b.id,
      b.bet_uid,
      b.bet_slot,
      b.round_id,
      r.round_no,
      b.stake,
      b.status,
      b.auto_cashout_multiplier,
      b.cashout_multiplier,
      b.cashout_source,
      b.payout,
      b.created_at,
      b.cashed_out_at,
      b.refunded_at,
      r.crash_multiplier
    from public.jl_aviator_bets b
    join public.jl_aviator_rounds r on r.id=b.round_id
    where b.player_id=v_player
      and (p_before_id is null or b.id<p_before_id)
    order by b.id desc
    limit v_limit
  )
  select
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id',s.id,
          'bet_uid',s.bet_uid,
          'bet_slot',s.bet_slot,
          'round_id',s.round_id,
          'round_no',s.round_no,
          'stake',s.stake,
          'status',s.status,
          'auto_cashout_multiplier',s.auto_cashout_multiplier,
          'cashout_multiplier',s.cashout_multiplier,
          'cashout_source',s.cashout_source,
          'payout',s.payout,
          'created_at',s.created_at,
          'cashed_out_at',s.cashed_out_at,
          'refunded_at',s.refunded_at,
          'crash_multiplier',s.crash_multiplier
        )
        order by s.id desc
      ),
      '[]'::jsonb
    ),
    min(s.id)
  into v_bets,v_next_before_id
  from selected s;

  if v_next_before_id is not null then
    select exists(
      select 1
      from public.jl_aviator_bets b
      where b.player_id=v_player
        and b.id<v_next_before_id
    )
    into v_has_more;
  end if;

  return jsonb_build_object(
    'ok',true,
    'bets',v_bets,
    'next_before_id',case when v_has_more then v_next_before_id else null end,
    'has_more',v_has_more
  );
end;
$function$;

revoke execute on function public.jl_aviator_my_history(text,integer,bigint)
from public;
grant execute on function public.jl_aviator_my_history(text,integer,bigint)
to anon,authenticated,service_role;

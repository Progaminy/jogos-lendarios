
create or replace function public.jl_check_funds(
  p_token text,
  p_game_type text,
  p_amount numeric
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  me uuid:=public.jl_player_id(p_token);
  cash numeric:=0;
  bonus numeric:=0;
  locked numeric:=0;
  available numeric:=0;
  reason text:='ok';
  redirect boolean:=false;
begin
  if p_amount is null or p_amount<0 then
    raise exception 'Valor inválido.';
  end if;

  if p_game_type not in ('number','pair','ludo','withdrawal') then
    raise exception 'Tipo de movimento financeiro inválido.';
  end if;

  cash:=public.jl_player_ledger_balance(me);

  if p_game_type in ('number','pair') then
    bonus:=public.jl_bonus_available(me,p_game_type);
    available:=cash+bonus;
    if available<p_amount then
      reason:='insufficient_balance';
      redirect:=true;
    end if;
  elsif p_game_type='ludo' then
    available:=cash;
    if available<p_amount then
      reason:='insufficient_balance';
      redirect:=true;
    end if;
  else
    locked:=public.jl_deposit_wager_locked(me);
    available:=greatest(0,cash-locked);

    if available<p_amount then
      if cash<p_amount then
        reason:='insufficient_balance';
        redirect:=true;
      else
        reason:='deposit_not_played';
        redirect:=false;
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'ok',available>=p_amount,
    'game_type',p_game_type,
    'required',round(p_amount,2),
    'cash_balance',round(cash,2),
    'balance_confirmed',true,
    'bonus_available',round(bonus,2),
    'deposit_locked',round(locked,2),
    'available',round(available,2),
    'shortfall',round(greatest(0,p_amount-available),2),
    'reason',reason,
    'redirect_to_deposit',redirect
  );
end;
$function$;

create or replace function public.jl_ludo_my_status(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  me uuid:=public.jl_player_id(p_token);
  rid uuid;
  online_total int;
  confirmed_balance numeric;
begin
  update public.player_sessions
  set last_seen_at=now()
  where token_hash=public.jl_token_hash(p_token)
    and expires_at>now();

  delete from public.ludo_waiting_queue
  where expires_at<=now();

  select count(distinct player_id)
  into online_total
  from public.player_sessions
  where expires_at>now()
    and last_seen_at>=now()-interval '20 seconds';

  select r.id into rid
  from public.ludo_room_players rp
  join public.ludo_rooms r on r.id=rp.room_id
  where rp.player_id=me
    and rp.status<>'left'
    and r.status in ('waiting','negotiating','funding','playing')
  order by r.created_at desc
  limit 1;

  confirmed_balance:=public.jl_player_ledger_balance(me);

  return jsonb_build_object(
    'identity',jsonb_build_object(
      'player_id',me,
      'name',(select name from public.players where id=me),
      'code',public.jl_ludo_display_code(me),
      'house_number',(select house_number from public.ludo_player_codes where player_id=me),
      'balance',confirmed_balance,
      'balance_confirmed',true
    ),
    'active_room_id',rid,
    'online_count',online_total,
    'queue',(select case when w.player_id is null then null else to_jsonb(w) end
             from public.ludo_waiting_queue w where w.player_id=me),
    'invites',public.jl_ludo_my_invites(p_token)
  );
end;
$function$;

create or replace function public.jl_player_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_player public.players%rowtype;
  v_balance numeric;
  v_public jsonb;
  v_bets jsonb;
  v_pair_bets jsonb;
  v_deposits jsonb;
  v_withdrawals jsonb;
  v_bonus_total numeric;
  v_bonus_number numeric;
  v_bonus_pair numeric;
  v_bonus_grants jsonb;
  v_deposit_locked numeric;
  v_withdrawable numeric;
begin
  select * into v_player from public.players where id=v_player_id;
  v_balance:=public.jl_player_ledger_balance(v_player_id);
  select public.jl_public_state() into v_public;

  v_deposit_locked:=public.jl_deposit_wager_locked(v_player_id);
  v_withdrawable:=greatest(0,v_balance-v_deposit_locked);

  select
    coalesce(sum(remaining_amount) filter(where status='active'),0),
    coalesce(sum(remaining_amount) filter(where status='active' and game_scope in ('number','both')),0),
    coalesce(sum(remaining_amount) filter(where status='active' and game_scope in ('pair','both')),0)
  into v_bonus_total,v_bonus_number,v_bonus_pair
  from public.bonus_grants where player_id=v_player_id;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_bonus_grants
  from (
    select id,game_scope,bonus_type,original_amount,remaining_amount,played_amount,status,note,created_at
    from public.bonus_grants
    where player_id=v_player_id
    order by created_at desc
    limit 30
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_bets
  from (
    select b.id,b.selected_number,b.amount,b.cash_amount,b.bonus_amount,b.won,b.payout,b.created_at,r.round_no,
      case when r.status='published' then r.drawn_number else null end drawn_number,r.status round_status
    from public.bets b join public.game_rounds r on r.id=b.round_id
    where b.player_id=v_player_id order by b.created_at desc limit 30
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_pair_bets
  from (
    select pb.id,pb.number_a,pb.number_b,pb.amount,pb.cash_amount,pb.bonus_amount,pb.won,pb.payout,pb.created_at,r.round_no,
      case when r.status='published' then r.pair_drawn_a else null end pair_drawn_a,
      case when r.status='published' then r.pair_drawn_b else null end pair_drawn_b,
      r.status round_status
    from public.pair_bets pb join public.game_rounds r on r.id=pb.round_id
    where pb.player_id=v_player_id order by pb.created_at desc limit 30
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_deposits
  from (
    select d.id,d.amount,d.note,d.status,d.created_at,d.reviewed_at,
           coalesce(w.remaining_amount,0) wager_remaining
    from public.deposit_requests d
    left join public.deposit_wager_requirements w on w.deposit_request_id=d.id
    where d.player_id=v_player_id
    order by d.created_at desc
    limit 20
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_withdrawals
  from (
    select id,amount,status,reason,created_at,reviewed_at
    from public.withdrawal_requests
    where player_id=v_player_id
    order by created_at desc
    limit 20
  ) x;

  return v_public || jsonb_build_object(
    'player',jsonb_build_object(
      'id',v_player.id,
      'name',v_player.name,
      'phone',v_player.phone,
      'balance',v_balance,
      'balance_confirmed',true,
      'withdrawable_balance',v_withdrawable,
      'deposit_locked',v_deposit_locked,
      'bonus_balance',v_bonus_total,
      'blocked',v_player.blocked
    ),
    'deposit_wager',jsonb_build_object(
      'locked',v_deposit_locked,
      'withdrawable',v_withdrawable
    ),
    'bonus',jsonb_build_object(
      'total',v_bonus_total,'number',v_bonus_number,'pair',v_bonus_pair,'grants',v_bonus_grants
    ),
    'bets',v_bets,
    'pair_bets',v_pair_bets,
    'deposits',v_deposits,
    'withdrawals',v_withdrawals
  );
end;
$function$;

create or replace function public.jl_aviator_player_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $function$
declare
  v_player uuid:=public.jl_player_id(p_token);
  v_balance numeric;
  v_bets jsonb;
begin
  v_balance:=public.jl_player_ledger_balance(v_player);

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',q.id,
        'round_id',q.round_id,
        'stake',q.stake,
        'status',q.status,
        'auto_cashout_multiplier',q.auto_cashout_multiplier,
        'cashout_multiplier',q.cashout_multiplier,
        'cashout_source',q.cashout_source,
        'payout',q.payout,
        'cashed_out_at',q.cashed_out_at,
        'payout_transaction_id',q.payout_transaction_id
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
      b.auto_cashout_multiplier,
      b.cashout_multiplier,
      b.cashout_source,
      b.payout,
      b.cashed_out_at,
      b.payout_transaction_id
    from public.jl_aviator_bets b
    join public.jl_aviator_rounds r on r.id=b.round_id
    where b.player_id=v_player
      and r.status in ('OPEN','LOCKED','FLYING','CRASHED','SETTLED')
      and b.created_at>now()-interval '1 day'
    order by b.id desc
    limit 20
  ) q;

  return jsonb_build_object(
    'balance',v_balance,
    'balance_confirmed',true,
    'bets',v_bets
  );
end
$function$;

create or replace function public.jl_request_withdrawal(p_player_id uuid, p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_player players%rowtype;
  v_reserved numeric(14,2);
  v_request withdrawal_requests%rowtype;
  v_available numeric(14,2);
begin
  if p_amount is null or p_amount < 1 or p_amount > 1000000 then
    raise exception 'INVALID_AMOUNT';
  end if;

  select * into v_player from players where id = p_player_id for update;
  if not found then raise exception 'PLAYER_NOT_FOUND'; end if;
  if v_player.blocked then raise exception 'PLAYER_BLOCKED'; end if;

  select coalesce(sum(amount), 0) into v_reserved
  from withdrawal_requests
  where player_id = p_player_id and status = 'pending';

  v_available := round(v_player.balance - v_reserved, 2);

  if v_available < p_amount then
    insert into withdrawal_requests(player_id, amount, status, reviewed_at)
    values (p_player_id, round(p_amount, 2), 'rejected', now())
    returning * into v_request;

    insert into audit_log(action, details)
    values ('withdrawal.auto_rejected', jsonb_build_object(
      'requestId', v_request.id,
      'playerId', p_player_id,
      'amount', v_request.amount,
      'availableBalance', v_available,
      'reason', 'INSUFFICIENT_AVAILABLE_BALANCE'
    ));

    return jsonb_build_object(
      'id', v_request.id,
      'playerId', v_request.player_id,
      'amount', v_request.amount,
      'status', v_request.status,
      'reason', 'insufficient_balance',
      'availableBalance', v_available,
      'createdAt', v_request.created_at,
      'reviewedAt', v_request.reviewed_at
    );
  end if;

  insert into withdrawal_requests(player_id, amount)
  values (p_player_id, round(p_amount, 2))
  returning * into v_request;

  insert into audit_log(action, details)
  values ('withdrawal.requested', jsonb_build_object(
    'requestId', v_request.id,
    'playerId', p_player_id,
    'amount', v_request.amount
  ));

  return jsonb_build_object(
    'id', v_request.id,
    'playerId', v_request.player_id,
    'amount', v_request.amount,
    'status', v_request.status,
    'createdAt', v_request.created_at
  );
end;
$function$;

create or replace function public.jl_open_round_at(p_closes_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_round game_rounds%rowtype;
begin
  if exists(select 1 from game_rounds where status in ('open','closed','drawn')) then
    raise exception 'ROUND_ACTIVE';
  end if;
  if p_closes_at is null or p_closes_at <= now() or p_closes_at > now() + interval '24 hours' then
    raise exception 'INVALID_TIMER';
  end if;

  insert into game_rounds(status, closes_at)
  values ('open', p_closes_at)
  returning * into v_round;

  insert into audit_log(action, details)
  values ('round.opened', jsonb_build_object('roundId',v_round.id,'closesAt',v_round.closes_at));

  return jsonb_build_object('id',v_round.id,'status',v_round.status,'openedAt',v_round.opened_at,'closesAt',v_round.closes_at);
end;
$function$;

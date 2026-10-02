-- Aviator: dois painéis independentes de aposta por jogador/rodada.
-- Compatibilidade: o RPC legado continua com o comportamento anterior.
-- A interface de dois painéis usa jl_aviator_place_bet_slot(..., p_bet_slot).

alter table public.jl_aviator_bets
  add column if not exists bet_slot smallint not null default 1;

alter table public.jl_aviator_bets
  drop constraint if exists jl_aviator_bets_bet_slot_check;

alter table public.jl_aviator_bets
  add constraint jl_aviator_bets_bet_slot_check
  check (bet_slot in (1,2));

drop index if exists public.jl_aviator_bets_player_round_uidx;

-- Mantém o nome histórico do índice para não quebrar o preflight já existente,
-- mas a unicidade passa a ser por slot.
create unique index jl_aviator_bets_player_round_uidx
  on public.jl_aviator_bets(round_id,player_id,bet_slot);

create or replace function public.jl_aviator_place_bet_slot(
  p_token text,
  p_amount numeric,
  p_request_key text,
  p_auto_cashout_multiplier numeric,
  p_bet_slot integer
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_player public.players;
  v_round public.jl_aviator_rounds;
  v_bet public.jl_aviator_bets;
  v_existing public.jl_aviator_bets;
  v_enabled boolean;
  v_auto numeric;
  v_tx uuid;
  v_slot smallint;
  v_server_received_at timestamptz:=clock_timestamp();
begin
  perform public.jl_rate_limit_enforce(
    'aviator_bet',
    v_player_id::text,
    8,10,40,60
  );

  if p_bet_slot not in (1,2) then
    raise exception 'Painel de aposta invalido.';
  end if;
  v_slot:=p_bet_slot::smallint;

  if p_request_key is null
     or length(trim(p_request_key))<8
     or length(p_request_key)>100 then
    raise exception 'Chave da aposta invalida.';
  end if;

  if p_auto_cashout_multiplier is not null then
    if p_auto_cashout_multiplier<1.01
       or round(p_auto_cashout_multiplier,2)<>p_auto_cashout_multiplier then
      raise exception 'Cash-out automatico deve ser pelo menos 1,01x e usar no maximo 2 casas decimais.';
    end if;
    v_auto:=round(p_auto_cashout_multiplier,2);
  end if;

  perform pg_advisory_xact_lock(
    hashtext(
      'jl_aviator_bet_'||
      v_player_id::text||'_'||
      trim(p_request_key)
    )
  );

  perform pg_advisory_xact_lock_shared(
    hashtext('jl_aviator_maintenance')
  );

  select *
    into v_bet
  from public.jl_aviator_bets
  where player_id=v_player_id
    and request_key=p_request_key;

  if v_bet.id is not null then
    select id into v_tx
    from public.transactions
    where aviator_bet_id=v_bet.id
      and aviator_operation='BET';

    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'bet_id',v_bet.id,
      'bet_uid',v_bet.bet_uid,
      'bet_slot',v_bet.bet_slot,
      'round_id',v_bet.round_id,
      'round_no',(select round_no from public.jl_aviator_rounds where id=v_bet.round_id),
      'transaction_id',v_tx,
      'stake',v_bet.stake,
      'auto_cashout_multiplier',v_bet.auto_cashout_multiplier
    );
  end if;

  select enabled into v_enabled
  from public.jl_aviator_settings
  where id=true;

  if coalesce(v_enabled,true)=false then
    raise exception 'Aviator em manutencao. Volte em breve.';
  end if;

  if p_amount is null or p_amount<0.50 or p_amount>500 then
    raise exception 'Valor de aposta invalido. Minimo 0,50 MZN e maximo 500 MZN.';
  end if;

  select *
    into v_round
  from public.jl_aviator_rounds
  where status='OPEN'
    and betting_closes_at is not null
    and betting_closes_at>v_server_received_at
  order by id desc
  limit 1
  for share;

  if v_round.id is null then
    raise exception 'Nao ha rodada Aviator aberta.';
  end if;

  perform public.jl_lock_player_wallet(v_player_id);

  select *
    into v_player
  from public.players
  where id=v_player_id
  for update;

  if v_player.blocked then
    raise exception 'Jogador bloqueado.';
  end if;

  select *
    into v_existing
  from public.jl_aviator_bets
  where round_id=v_round.id
    and player_id=v_player_id
    and bet_slot=v_slot
  limit 1;

  if v_existing.id is not null then
    raise exception 'Ja existe uma aposta neste painel nesta rodada.';
  end if;

  if v_player.balance<p_amount then
    raise exception 'Saldo insuficiente.';
  end if;

  update public.players
     set balance=round(balance-p_amount,2),
         updated_at=clock_timestamp()
   where id=v_player_id;

  insert into public.jl_aviator_bets(
    round_id,
    player_id,
    stake,
    auto_cashout_multiplier,
    request_key,
    bet_slot
  )
  values(
    v_round.id,
    v_player_id,
    round(p_amount,2),
    v_auto,
    p_request_key,
    v_slot
  )
  returning * into v_bet;

  v_tx:=gen_random_uuid();

  insert into public.transactions(
    id,player_id,kind,amount,status,note,
    aviator_bet_id,aviator_operation
  )
  values(
    v_tx,
    v_player_id,
    'aviator_bet',
    -round(p_amount,2),
    'completed',
    'Aposta Aviator painel '||v_slot||' rodada '||v_round.id,
    v_bet.id,
    'BET'
  );

  insert into public.audit_log(action,details)
  values(
    'aviator.bet_placed',
    jsonb_build_object(
      'roundId',v_round.id,
      'roundNo',v_round.round_no,
      'betId',v_bet.id,
      'betUid',v_bet.bet_uid,
      'betSlot',v_slot,
      'playerId',v_player_id,
      'transactionId',v_tx,
      'stake',v_bet.stake,
      'autoCashoutMultiplier',v_bet.auto_cashout_multiplier,
      'serverAcceptedAt',v_bet.created_at
    )
  );

  return jsonb_build_object(
    'ok',true,
    'already_processed',false,
    'bet_id',v_bet.id,
    'bet_uid',v_bet.bet_uid,
    'bet_slot',v_slot,
    'round_id',v_bet.round_id,
    'round_no',v_round.round_no,
    'transaction_id',v_tx,
    'stake',v_bet.stake,
    'auto_cashout_multiplier',v_bet.auto_cashout_multiplier,
    'server_accepted_at',v_bet.created_at,
    'balance',v_player.balance-round(p_amount,2)
  );
end;
$function$;

revoke all on function public.jl_aviator_place_bet_slot(
  text,numeric,text,numeric,integer
) from public;
grant execute on function public.jl_aviator_place_bet_slot(
  text,numeric,text,numeric,integer
) to anon,authenticated,service_role;

create or replace function public.jl_aviator_player_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
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
        'bet_uid',q.bet_uid,
        'bet_slot',q.bet_slot,
        'round_id',q.round_id,
        'round_no',q.round_no,
        'stake',q.stake,
        'status',q.status,
        'auto_cashout_multiplier',q.auto_cashout_multiplier,
        'cashout_multiplier',q.cashout_multiplier,
        'cashout_source',q.cashout_source,
        'payout',q.payout,
        'cashed_out_at',q.cashed_out_at,
        'payout_transaction_id',q.payout_transaction_id,
        'refunded_at',q.refunded_at,
        'refund_transaction_id',q.refund_transaction_id
      )
      order by q.id
    ),
    '[]'::jsonb
  )
  into v_bets
  from (
    select
      b.id,b.bet_uid,b.bet_slot,b.round_id,r.round_no,
      b.stake,b.status,b.auto_cashout_multiplier,
      b.cashout_multiplier,b.cashout_source,b.payout,
      b.cashed_out_at,b.payout_transaction_id,
      b.refunded_at,b.refund_transaction_id
    from public.jl_aviator_bets b
    join public.jl_aviator_rounds r on r.id=b.round_id
    where b.player_id=v_player
      and r.status in ('OPEN','LOCKED','FLYING','CRASHED','SETTLED')
      and b.created_at>clock_timestamp()-interval '1 day'
    order by b.id desc
    limit 40
  ) q;

  return jsonb_build_object(
    'balance',v_balance,
    'balance_confirmed',true,
    'bets',v_bets
  );
end;
$function$;

revoke all on function public.jl_aviator_player_state(text) from public;
grant execute on function public.jl_aviator_player_state(text)
to anon,authenticated,service_role;

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
    12,10,80,60
  );

  select
    b.id,b.bet_uid,b.bet_slot,b.round_id,r.round_no,
    b.stake,b.status,b.auto_cashout_multiplier,
    b.cashout_multiplier,b.cashout_source,b.payout,
    b.cashed_out_at,b.payout_transaction_id,
    b.refunded_at,b.refund_transaction_id
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
      'bet_slot',v_bet.bet_slot,
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

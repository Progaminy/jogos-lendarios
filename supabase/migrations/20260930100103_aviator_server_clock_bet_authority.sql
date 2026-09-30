create or replace function public.jl_aviator_enforce_server_bet_window()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_status text;
  v_closes_at timestamptz;
  v_server_now timestamptz:=clock_timestamp();
begin
  select status,betting_closes_at
    into v_status,v_closes_at
  from public.jl_aviator_rounds
  where id=new.round_id
  for share;

  if not found then
    raise exception 'Rodada Aviator inexistente.';
  end if;

  if v_status<>'OPEN'
     or v_closes_at is null
     or v_server_now>=v_closes_at then
    raise exception 'Apostas fechadas pelo relogio do servidor.';
  end if;

  -- Nunca confiar em created_at enviado pelo cliente/caller.
  new.created_at:=v_server_now;
  return new;
end;
$function$;

revoke all on function public.jl_aviator_enforce_server_bet_window()
from public,anon,authenticated;

grant execute on function public.jl_aviator_enforce_server_bet_window()
to service_role;

drop trigger if exists jl_aviator_server_bet_window
on public.jl_aviator_bets;

create trigger jl_aviator_server_bet_window
before insert on public.jl_aviator_bets
for each row
execute function public.jl_aviator_enforce_server_bet_window();

CREATE OR REPLACE FUNCTION public.jl_aviator_place_bet(p_token text, p_amount numeric, p_request_key text, p_auto_cashout_multiplier numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_player public.players;
  v_round public.jl_aviator_rounds;
  v_bet public.jl_aviator_bets;
  v_existing public.jl_aviator_bets;
  v_enabled boolean;
  v_auto numeric;
  v_tx uuid;
  v_server_received_at timestamptz:=clock_timestamp();
begin
  perform public.jl_rate_limit_enforce('aviator_bet',v_player_id::text,6,10,30,60);

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
      v_player_id::text||
      '_'||
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
    select id
      into v_tx
    from public.transactions
    where aviator_bet_id=v_bet.id
      and aviator_operation='BET';

    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'bet_id',v_bet.id,
      'bet_uid',v_bet.bet_uid,
      'round_id',v_bet.round_id,
      'round_no',(select round_no from public.jl_aviator_rounds where id=v_bet.round_id),
      'transaction_id',v_tx,
      'stake',v_bet.stake,
      'auto_cashout_multiplier',v_bet.auto_cashout_multiplier
    );
  end if;

  select enabled
    into v_enabled
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
  limit 1;

  if v_existing.id is not null then
    raise exception 'Ja existe uma aposta nesta rodada.';
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
    request_key
  )
  values(
    v_round.id,
    v_player_id,
    round(p_amount,2),
    v_auto,
    p_request_key
  )
  returning * into v_bet;

  v_tx:=gen_random_uuid();

  insert into public.transactions(
    id,
    player_id,
    kind,
    amount,
    status,
    note,
    aviator_bet_id,
    aviator_operation
  )
  values(
    v_tx,
    v_player_id,
    'aviator_bet',
    -round(p_amount,2),
    'completed',
    'Aposta Aviator rodada '||v_round.id,
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
    'round_id',v_bet.round_id,
    'round_no',v_round.round_no,
    'transaction_id',v_tx,
    'stake',v_bet.stake,
    'auto_cashout_multiplier',v_bet.auto_cashout_multiplier,
    'server_accepted_at',v_bet.created_at,
    'balance',v_player.balance-round(p_amount,2)
  );
end
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_place_bet(p_token text, p_amount numeric)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  select public.jl_aviator_place_bet(
    p_token,
    p_amount,
    'legacy-bet:'||gen_random_uuid()::text,
    null::numeric
  );
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_lock_round(p_round_id bigint)
 RETURNS jl_aviator_rounds
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_round public.jl_aviator_rounds;
  v_bank public.jl_aviator_bank;
  v_total numeric;
  v_seed text;
  v_commit text;
  v_visual numeric;
  v_financial numeric;
  v_locked_effective numeric;
  v_payload text;
  v_lock_commit text;
begin
  select *
    into v_round
  from public.jl_aviator_rounds
  where id=p_round_id
  for update;

  if not found or v_round.status<>'OPEN' then
    raise exception 'Rodada nao esta OPEN';
  end if;

  if v_round.round_seed_commit is null
     or not exists(
       select 1 from public.jl_aviator_round_secrets
       where round_id=p_round_id
     ) then
    perform public.jl_aviator_prepare_fairness(p_round_id);

    select *
      into v_round
    from public.jl_aviator_rounds
    where id=p_round_id;
  end if;

  select seed
    into v_seed
  from public.jl_aviator_round_secrets
  where round_id=p_round_id;

  v_commit:=encode(extensions.digest(v_seed,'sha256'),'hex');

  if v_round.round_seed_commit<>v_commit then
    raise exception 'Seed nao corresponde ao compromisso pre-aposta';
  end if;

  v_visual:=public.jl_aviator_fairness_visual_target(v_commit);

  select *
    into v_bank
  from public.jl_aviator_bank
  where id=true
  for update;

  select coalesce(sum(stake),0)
    into v_total
  from public.jl_aviator_bets
  where round_id=p_round_id
    and status='ACTIVE';

  v_financial:=public.jl_aviator_financial_ceiling(
    v_bank.balance,
    v_total,
    v_bank.exposure_ratio
  );

  v_locked_effective:=case
    when v_total=0 then v_visual
    else v_financial
  end;

  v_payload:=public.jl_aviator_fairness_lock_payload(
    p_round_id,
    v_commit,
    v_total,
    v_financial,
    v_visual,
    v_locked_effective
  );

  v_lock_commit:=encode(extensions.digest(v_payload,'sha256'),'hex');

  update public.jl_aviator_rounds
     set status='LOCKED',
         locked_at=clock_timestamp(),
         bank_balance_snapshot=v_bank.balance,
         exposure_ratio_snapshot=v_bank.exposure_ratio,
         risk_reserve=round(v_bank.balance*v_bank.exposure_ratio,2),
         total_staked=v_total,
         financial_ceiling=v_financial,
         visual_target=v_visual,
         round_seed_commit=v_commit,
         visual_seed_commit=v_commit,
         lock_proof_commit=v_lock_commit,
         locked_effective_target=v_locked_effective,
         effective_target=v_locked_effective,
         round_seed_reveal=null,
         visual_seed_reveal=null,
         visual_extension=(v_total=0),
         fairness_version='JL-AVIATOR-PF-v2'
   where id=p_round_id
  returning * into v_round;

  return v_round;
end
$function$;
create or replace function public.jl_lock_player_wallet(p_player_id uuid)
returns void
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
begin
  if p_player_id is null then
    raise exception 'Identidade financeira inválida.';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('jl_player_wallet:'||p_player_id::text,0)
  );
end;
$function$;

revoke all on function public.jl_lock_player_wallet(uuid)
from public,anon,authenticated;

grant execute on function public.jl_lock_player_wallet(uuid)
to service_role;

CREATE OR REPLACE FUNCTION public.jl_aviator_place_bet(p_token text, p_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_player_id uuid:=public.jl_player_id(p_token);
declare v_player public.players%rowtype;
declare v_round public.jl_aviator_rounds%rowtype;
declare v_bet public.jl_aviator_bets%rowtype;
begin
  if p_amount is null or p_amount < 1 or p_amount > 1000000 then raise exception 'Valor de aposta invalido.'; end if;
  select * into v_round from public.jl_aviator_rounds where status='OPEN' order by id desc limit 1 for update;
  if v_round.id is null then raise exception 'Nao ha rodada Aviator aberta.'; end if;
  perform public.jl_lock_player_wallet(v_player_id);

  select * into v_player from public.players where id=v_player_id for update;
  if v_player.blocked then raise exception 'Jogador bloqueado.'; end if;
  if v_player.balance < p_amount then raise exception 'Saldo insuficiente.'; end if;

  update public.players set balance=round(balance-p_amount,2),updated_at=now() where id=v_player_id;
  insert into public.jl_aviator_bets(round_id,player_id,stake)
  values(v_round.id,v_player_id,round(p_amount,2)) returning * into v_bet;
  insert into public.transactions(player_id,kind,amount,status,note)
  values(v_player_id,'aviator_bet',-round(p_amount,2),'completed','Aposta Aviator rodada '||v_round.id);
  insert into public.audit_log(action,details)
  values('aviator.bet_placed',jsonb_build_object('roundId',v_round.id,'betId',v_bet.id,'playerId',v_player_id,'stake',v_bet.stake));
  return jsonb_build_object('ok',true,'bet_id',v_bet.id,'round_id',v_round.id,'stake',v_bet.stake,'balance',v_player.balance-round(p_amount,2));
end $function$;

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
begin
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
      'round_id',v_bet.round_id,
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
    and (
      betting_closes_at is null
      or betting_closes_at>clock_timestamp()
    )
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
      'betId',v_bet.id,
      'playerId',v_player_id,
      'transactionId',v_tx,
      'stake',v_bet.stake,
      'autoCashoutMultiplier',v_bet.auto_cashout_multiplier
    )
  );

  return jsonb_build_object(
    'ok',true,
    'already_processed',false,
    'bet_id',v_bet.id,
    'round_id',v_bet.round_id,
    'transaction_id',v_tx,
    'stake',v_bet.stake,
    'auto_cashout_multiplier',v_bet.auto_cashout_multiplier,
    'balance',v_player.balance-round(p_amount,2)
  );
end
$function$;

CREATE OR REPLACE FUNCTION public.jl_ludo_commit_stake(p_token text, p_room uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  pl public.players%rowtype;
  rp public.ludo_room_players%rowtype;
  cleared numeric:=0;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.id is null or r.status<>'funding' then raise exception 'A sala ainda não está na fase de aposta.'; end if;
  if r.action_deadline<=now() then raise exception 'Tempo para confirmar a aposta expirou.'; end if;

  select * into rp
  from public.ludo_room_players
  where room_id=p_room and player_id=me and status<>'left'
  for update;

  if rp.player_id is null or rp.accepted_rules_version<>r.rules_version then
    raise exception 'Aceite primeiro as regras atuais.';
  end if;

  if rp.stake_paid then return public.jl_ludo_room_state(p_token,p_room); end if;

  perform public.jl_lock_player_wallet(me);

  select * into pl from public.players where id=me for update;
  if pl.blocked then raise exception 'Conta bloqueada.'; end if;
  if pl.balance<r.bet_amount then raise exception 'Saldo insuficiente para a aposta desta sala.'; end if;

  update public.players set balance=balance-r.bet_amount,updated_at=now() where id=me;
  cleared:=public.jl_apply_cash_wager(me,r.bet_amount,'ludo_stake',p_room);

  update public.ludo_room_players
  set stake_paid=true,stake_amount=r.bet_amount
  where room_id=p_room and player_id=me;

  update public.ludo_rooms
  set pot=pot+r.bet_amount,updated_at=now()
  where id=p_room;

  insert into public.transactions(player_id,kind,amount,status,reference_id,note)
  values(me,'ludo_stake',-r.bet_amount,'completed',p_room,
         'Aposta Ludo '||r.code||' · '||cleared||' MZN de depósito liberado');

  perform public.jl_ludo_event(
    p_room,me,'stake_committed',
    jsonb_build_object('amount',r.bet_amount,'deposit_wager_cleared',cleared)
  );

  if not exists(
    select 1
    from public.ludo_room_players
    where room_id=p_room and status<>'left' and not stake_paid
  ) then
    perform public.jl_ludo_start_game(p_room);
  end if;

  return public.jl_ludo_room_state(p_token,p_room);
end;
$function$;

CREATE OR REPLACE FUNCTION public.jl_ludo_reenter(p_token text, p_room uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  rp public.ludo_room_players%rowtype;
  pl public.players%rowtype;
  amt numeric;
  cleared numeric:=0;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  select * into rp from public.ludo_room_players where room_id=p_room and player_id=me for update;

  if r.status<>'playing' or rp.status<>'reentry' then
    raise exception 'Reentrada indisponível.';
  end if;

  amt:=(r.rules->>'reentry_amount')::numeric;
  perform public.jl_lock_player_wallet(me);

  select * into pl from public.players where id=me for update;
  if pl.balance<amt then raise exception 'Saldo insuficiente para reentrar.'; end if;

  update public.players set balance=balance-amt,updated_at=now() where id=me;
  cleared:=public.jl_apply_cash_wager(me,amt,'ludo_reentry',p_room);

  update public.ludo_rooms set pot=pot+amt,updated_at=now() where id=p_room;
  update public.ludo_room_players
  set status='active',reentry_deadline=null
  where room_id=p_room and player_id=me;

  insert into public.transactions(player_id,kind,amount,status,reference_id,note)
  values(me,'ludo_reentry',-amt,'completed',p_room,
         'Reentrada no Ludo '||r.code||' · '||cleared||' MZN de depósito liberado');

  perform public.jl_ludo_event(
    p_room,me,'player_reentered',
    jsonb_build_object(
      'amount',amt,
      'late_reconnect_allowed',true,
      'deposit_wager_cleared',cleared
    )
  );

  return public.jl_ludo_room_state(p_token,p_room);
end;
$function$;

CREATE OR REPLACE FUNCTION public.jl_place_bet(p_token text, p_selected_number integer, p_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_player public.players%rowtype;
  v_round public.game_rounds%rowtype;
  v_settings public.game_settings%rowtype;
  v_bet_id uuid;
  v_total_after numeric;
  v_min_after numeric;
  v_bonus_available numeric:=0;
  v_bonus_used numeric:=0;
  v_cash_used numeric:=0;
  v_consumed numeric:=0;
  v_deposit_cleared numeric:=0;
begin
  select * into v_settings from public.game_settings where game_type='number';
  if not v_settings.enabled then raise exception 'Número Lendário está temporariamente desativado.'; end if;
  if p_selected_number<0 or p_selected_number>10 then raise exception 'Escolha um número de 0 a 10.'; end if;
  if p_amount is null or p_amount<>trunc(p_amount) or p_amount<v_settings.min_bet or p_amount>v_settings.max_bet then
    raise exception 'A aposta deve ser um valor inteiro entre % e % MZN.',v_settings.min_bet,v_settings.max_bet;
  end if;

  select * into v_round from public.game_rounds
  where game_type='number' and status='open' and closes_at>now()
  order by opened_at desc limit 1 for update;
  if v_round.id is null then raise exception 'As apostas do Número Lendário estão fechadas neste momento.'; end if;

  perform public.jl_lock_player_wallet(v_player_id);

  select * into v_player from public.players where id=v_player_id for update;
  if v_player.blocked then raise exception 'Esta conta está bloqueada.'; end if;

  v_bonus_available:=public.jl_bonus_available(v_player_id,'number');
  if v_player.balance+v_bonus_available<p_amount then
    raise exception 'Saldo e bónus insuficientes para esta aposta.';
  end if;

  v_bonus_used:=least(p_amount,v_bonus_available);
  v_cash_used:=p_amount-v_bonus_used;

  select coalesce(sum(amount),0)+p_amount into v_total_after
  from public.bets where round_id=v_round.id;

  select min(exposure) into v_min_after
  from (
    select n,coalesce(sum(b.amount),0)+case when n=p_selected_number then p_amount else 0 end exposure
    from generate_series(0,10) n
    left join public.bets b on b.round_id=v_round.id and b.selected_number=n
    group by n
  ) x;

  if v_min_after*v_settings.multiplier>=v_total_after then
    raise exception 'Esta aposta atingiria o limite de segurança da rodada. Escolha outro número ou aguarde a próxima rodada.';
  end if;

  insert into public.bets(round_id,player_id,selected_number,amount,cash_amount,bonus_amount)
  values(v_round.id,v_player_id,p_selected_number,p_amount,v_cash_used,v_bonus_used)
  returning id into v_bet_id;

  if v_bonus_used>0 then
    v_consumed:=public.jl_consume_bonus(v_player_id,'number',v_bonus_used,v_bet_id);
    if v_consumed<>v_bonus_used then raise exception 'Não foi possível reservar o bónus desta aposta.'; end if;
  end if;

  if v_cash_used>0 then
    update public.players set balance=balance-v_cash_used,updated_at=now() where id=v_player_id;
    v_deposit_cleared:=public.jl_apply_cash_wager(v_player_id,v_cash_used,'number_bet',v_bet_id);

    insert into public.transactions(player_id,kind,amount,status,reference_id,note)
    values(v_player_id,'bet',-v_cash_used,'completed',v_bet_id,
      'Aposta no Número Lendário · '||v_bonus_used||' MZN de bónus · '||
      v_deposit_cleared||' MZN de depósito liberado');
  end if;

  return jsonb_build_object(
    'ok',true,'bet_id',v_bet_id,'round_no',v_round.round_no,
    'selected_number',p_selected_number,'amount',p_amount,
    'cash_used',v_cash_used,'bonus_used',v_bonus_used,
    'deposit_wager_cleared',v_deposit_cleared,
    'balance',v_player.balance-v_cash_used,
    'deposit_locked',public.jl_deposit_wager_locked(v_player_id),
    'bonus_remaining',public.jl_bonus_available(v_player_id,'number')
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.jl_place_pair_bet(p_token text, p_number_a integer, p_number_b integer, p_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_player public.players%rowtype;
  v_round public.game_rounds%rowtype;
  v_settings public.game_settings%rowtype;
  v_bet_id uuid;
  v_a integer;
  v_b integer;
  v_total_after numeric;
  v_min_after numeric;
  v_bonus_available numeric:=0;
  v_bonus_used numeric:=0;
  v_cash_used numeric:=0;
  v_consumed numeric:=0;
  v_deposit_cleared numeric:=0;
begin
  select * into v_settings from public.game_settings where game_type='pair';
  if not v_settings.enabled then raise exception 'Dupla Lendária está temporariamente desativada.'; end if;
  if p_number_a is null or p_number_b is null then raise exception 'Escolha dois números.'; end if;
  if p_number_a<0 or p_number_a>10 or p_number_b<0 or p_number_b>10 then raise exception 'Escolha dois números entre 0 e 10.'; end if;
  if p_number_a=p_number_b then raise exception 'Escolha dois números diferentes.'; end if;

  v_a:=least(p_number_a,p_number_b);
  v_b:=greatest(p_number_a,p_number_b);

  if p_amount is null or p_amount<>trunc(p_amount) or p_amount<v_settings.min_bet or p_amount>v_settings.max_bet then
    raise exception 'A aposta deve ser um valor inteiro entre % e % MZN.',v_settings.min_bet,v_settings.max_bet;
  end if;

  select * into v_round from public.game_rounds
  where game_type='pair' and status='open' and closes_at>now()
  order by opened_at desc limit 1 for update;
  if v_round.id is null then raise exception 'As apostas da Dupla Lendária estão fechadas neste momento.'; end if;

  perform public.jl_lock_player_wallet(v_player_id);

  select * into v_player from public.players where id=v_player_id for update;
  if v_player.blocked then raise exception 'Esta conta está bloqueada.'; end if;

  v_bonus_available:=public.jl_bonus_available(v_player_id,'pair');
  if v_player.balance+v_bonus_available<p_amount then
    raise exception 'Saldo e bónus insuficientes para esta aposta.';
  end if;

  v_bonus_used:=least(p_amount,v_bonus_available);
  v_cash_used:=p_amount-v_bonus_used;

  select coalesce(sum(amount),0)+p_amount into v_total_after
  from public.pair_bets where round_id=v_round.id;

  select min(exposure) into v_min_after
  from (
    select a,b,coalesce(sum(pb.amount),0)+case when a=v_a and b=v_b then p_amount else 0 end exposure
    from generate_series(0,10) a
    cross join generate_series(0,10) b
    left join public.pair_bets pb on pb.round_id=v_round.id and pb.number_a=a and pb.number_b=b
    where a<b
    group by a,b
  ) x;

  if v_min_after*v_settings.multiplier>=v_total_after then
    raise exception 'Esta aposta atingiria o limite de segurança da rodada. Escolha outra combinação ou aguarde a próxima rodada.';
  end if;

  insert into public.pair_bets(round_id,player_id,number_a,number_b,amount,cash_amount,bonus_amount)
  values(v_round.id,v_player_id,v_a,v_b,p_amount,v_cash_used,v_bonus_used)
  returning id into v_bet_id;

  if v_bonus_used>0 then
    v_consumed:=public.jl_consume_bonus(v_player_id,'pair',v_bonus_used,v_bet_id);
    if v_consumed<>v_bonus_used then raise exception 'Não foi possível reservar o bónus desta aposta.'; end if;
  end if;

  if v_cash_used>0 then
    update public.players set balance=balance-v_cash_used,updated_at=now() where id=v_player_id;
    v_deposit_cleared:=public.jl_apply_cash_wager(v_player_id,v_cash_used,'pair_bet',v_bet_id);

    insert into public.transactions(player_id,kind,amount,status,reference_id,note)
    values(v_player_id,'bet',-v_cash_used,'completed',v_bet_id,
      'Aposta Dupla Lendária '||v_a||'+'||v_b||' · '||v_bonus_used||
      ' MZN de bónus · '||v_deposit_cleared||' MZN de depósito liberado');
  end if;

  return jsonb_build_object(
    'ok',true,'bet_id',v_bet_id,'round_no',v_round.round_no,
    'number_a',v_a,'number_b',v_b,'amount',p_amount,
    'cash_used',v_cash_used,'bonus_used',v_bonus_used,
    'deposit_wager_cleared',v_deposit_cleared,
    'balance',v_player.balance-v_cash_used,
    'deposit_locked',public.jl_deposit_wager_locked(v_player_id),
    'bonus_remaining',public.jl_bonus_available(v_player_id,'pair')
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.jl_request_withdrawal(p_token text, p_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_player public.players%rowtype;
  v_id uuid;
  v_locked numeric:=0;
  v_withdrawable numeric:=0;
begin
  if p_amount is null or p_amount<1 or p_amount>1000000 then
    raise exception 'Valor de saque inválido.';
  end if;

  perform public.jl_lock_player_wallet(v_player_id);

  select *
  into v_player
  from public.players
  where id=v_player_id
    and deleted_at is null
  for update;

  if v_player.id is null then
    raise exception 'Conta indisponível.';
  end if;

  v_locked:=public.jl_deposit_wager_locked(v_player_id);
  v_withdrawable:=greatest(0,v_player.balance-v_locked);

  if p_amount>v_withdrawable then
    insert into public.withdrawal_requests(
      player_id,amount,status,reason,reviewed_at
    )
    values(
      v_player_id,
      round(p_amount,2),
      'rejected',
      case
        when v_player.balance<p_amount then 'Saldo insuficiente'
        else 'Depósito ainda não foi jogado'
      end,
      now()
    )
    returning id into v_id;

    return jsonb_build_object(
      'ok',false,
      'request_id',v_id,
      'status','rejected',
      'message',
        case
          when v_player.balance<p_amount then 'Saque rejeitado automaticamente: saldo insuficiente.'
          else 'Saque bloqueado: parte do saldo vem de depósito que ainda precisa ser jogado.'
        end,
      'balance',v_player.balance,
      'deposit_locked',v_locked,
      'withdrawable_balance',v_withdrawable
    );
  end if;

  update public.players
  set balance=balance-round(p_amount,2),
      updated_at=now()
  where id=v_player_id;

  insert into public.withdrawal_requests(player_id,amount,status)
  values(v_player_id,round(p_amount,2),'pending')
  returning id into v_id;

  insert into public.transactions(
    player_id,kind,amount,status,reference_id,note
  )
  values(
    v_player_id,
    'withdrawal',
    -round(p_amount,2),
    'pending',
    v_id,
    'Valor reservado para saque'
  );

  return jsonb_build_object(
    'ok',true,
    'request_id',v_id,
    'status','pending',
    'message','Pedido de saque enviado para autorização.',
    'balance',v_player.balance-round(p_amount,2),
    'deposit_locked',v_locked,
    'withdrawable_balance',v_withdrawable-round(p_amount,2)
  );
end;
$function$;
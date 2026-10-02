-- Restore safe betting semantics after v4 admission regression.
-- New rounds use PF-v3: visual target 10x..500x remains precommitted,
-- while active financial exposure is bounded by the frozen financial ceiling.

create or replace function public.jl_aviator_prepare_fairness(
  p_round_id bigint
)
returns text
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  v_round public.jl_aviator_rounds;
  v_seed text;
  v_commit text;
  v_u numeric;
  v_target numeric;
  v_version text;
begin
  select *
    into v_round
  from public.jl_aviator_rounds
  where id=p_round_id
  for update;

  if not found then
    raise exception 'Rodada nao encontrada';
  end if;

  if v_round.status<>'OPEN' then
    raise exception 'Fairness so pode ser preparado em rodada OPEN';
  end if;

  -- Nao muda a regra de uma rodada que ja foi comprometida/publicada.
  v_version:=case
    when v_round.fairness_version in ('JL-AVIATOR-PF-v2','JL-AVIATOR-PF-v3')
      then v_round.fairness_version
    when v_round.round_seed_commit is not null
      then 'JL-AVIATOR-PF-v2'
    else 'JL-AVIATOR-PF-v3'
  end;

  select seed
    into v_seed
  from public.jl_aviator_round_secrets
  where round_id=p_round_id;

  if v_seed is null then
    v_seed:=encode(extensions.gen_random_bytes(32),'hex');
    v_commit:=encode(extensions.digest(v_seed,'sha256'),'hex');
    v_u:=('x'||substr(v_commit,1,13))::bit(52)::bigint::numeric
         / 4503599627370495::numeric;

    insert into public.jl_aviator_round_secrets(round_id,seed,unit_value)
    values(p_round_id,v_seed,v_u)
    on conflict(round_id) do nothing;

    select seed
      into v_seed
    from public.jl_aviator_round_secrets
    where round_id=p_round_id;
  end if;

  v_commit:=encode(extensions.digest(v_seed,'sha256'),'hex');

  v_target:=case
    when v_version='JL-AVIATOR-PF-v3'
      then public.jl_aviator_fairness_visual_target_v3(v_commit)
    else public.jl_aviator_fairness_visual_target(v_commit)
  end;

  if v_round.round_seed_commit is not null
     and v_round.round_seed_commit<>v_commit then
    raise exception 'Commit de fairness inconsistente';
  end if;

  update public.jl_aviator_rounds
     set fairness_version=v_version,
         round_seed_commit=v_commit,
         visual_seed_commit=v_commit,
         visual_target=v_target,
         round_seed_reveal=null,
         visual_seed_reveal=null
   where id=p_round_id;

  return v_commit;
end
$$;

revoke all on function public.jl_aviator_prepare_fairness(bigint)
from public,anon,authenticated;
grant execute on function public.jl_aviator_prepare_fairness(bigint)
to service_role;

create or replace function public.jl_aviator_lock_round(p_round_id bigint)
returns public.jl_aviator_rounds
language plpgsql
security definer
set search_path to 'pg_catalog','public','extensions'
as $$
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
  v_exposure_ratio numeric;
  v_version text;
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

  v_version:=case
    when v_round.fairness_version in ('JL-AVIATOR-PF-v2','JL-AVIATOR-PF-v3')
      then v_round.fairness_version
    else 'JL-AVIATOR-PF-v2'
  end;

  select seed
    into v_seed
  from public.jl_aviator_round_secrets
  where round_id=p_round_id;

  v_commit:=encode(extensions.digest(v_seed,'sha256'),'hex');

  if v_round.round_seed_commit<>v_commit then
    raise exception 'Seed nao corresponde ao compromisso pre-aposta';
  end if;

  v_visual:=case
    when v_version='JL-AVIATOR-PF-v3'
      then public.jl_aviator_fairness_visual_target_v3(v_commit)
    else public.jl_aviator_fairness_visual_target(v_commit)
  end;

  select *
    into v_bank
  from public.jl_aviator_bank
  where id=true
  for update;

  v_exposure_ratio:=public.jl_aviator_exposure_ratio_at(clock_timestamp());

  select coalesce(sum(stake),0)
    into v_total
  from public.jl_aviator_bets
  where round_id=p_round_id
    and status='ACTIVE';

  v_financial:=public.jl_aviator_financial_ceiling(
    v_bank.balance,
    v_total,
    v_exposure_ratio
  );

  v_locked_effective:=case
    when v_total=0 then v_visual
    else v_financial
  end;

  v_payload:=case
    when v_version='JL-AVIATOR-PF-v3' then
      public.jl_aviator_fairness_lock_payload_v3(
        p_round_id,
        v_commit,
        v_total,
        v_financial,
        v_visual,
        v_locked_effective
      )
    else
      public.jl_aviator_fairness_lock_payload(
        p_round_id,
        v_commit,
        v_total,
        v_financial,
        v_visual,
        v_locked_effective
      )
  end;

  v_lock_commit:=encode(extensions.digest(v_payload,'sha256'),'hex');

  update public.jl_aviator_rounds
     set status='LOCKED',
         engine_due_at=coalesce(v_round.takeoff_at,clock_timestamp()+interval '3 seconds'),
         locked_at=clock_timestamp(),
         bank_balance_snapshot=v_bank.balance,
         exposure_ratio_snapshot=v_exposure_ratio,
         risk_reserve=round(v_bank.balance*v_exposure_ratio,2),
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
         fairness_version=v_version
   where id=p_round_id
  returning * into v_round;

  perform public.jl_aviator_schedule_next_engine_event(p_round_id);

  select *
    into v_round
  from public.jl_aviator_rounds
  where id=p_round_id;

  return v_round;
end;
$$;

revoke all on function public.jl_aviator_lock_round(bigint)
from public,anon,authenticated;
grant execute on function public.jl_aviator_lock_round(bigint)
to service_role;

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

  -- v4 antigo exigia cobertura do alvo visual completo e podia bloquear
  -- todas as apostas quando a banca operacional era pequena. Rodadas novas
  -- usam v3: o teto financeiro e congelado no LOCK e o alvo visual continua
  -- precomprometido para a extensao sem exposicao.
  if v_round.fairness_version='JL-AVIATOR-PF-v4' then
    raise exception 'Rodada em transicao de seguranca. Aguarde a proxima rodada.';
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

-- If the currently open v4 round has no accepted bets, it is safe to
-- continue it immediately under the v3 semantics because v4 and v3 use
-- the same precommitted visual-target derivation.
update public.jl_aviator_rounds r
   set fairness_version='JL-AVIATOR-PF-v3',
       exposure_ratio_snapshot=null
 where r.status='OPEN'
   and r.fairness_version='JL-AVIATOR-PF-v4'
   and not exists(
     select 1
     from public.jl_aviator_bets b
     where b.round_id=r.id
       and b.status='ACTIVE'
   );

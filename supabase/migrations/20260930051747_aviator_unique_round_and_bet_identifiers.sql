
alter table public.jl_aviator_rounds
  add column if not exists round_no bigint
  generated always as (id) stored;

create unique index if not exists jl_aviator_rounds_round_no_uidx
  on public.jl_aviator_rounds(round_no);

alter table public.jl_aviator_bets
  add column if not exists bet_uid uuid;

update public.jl_aviator_bets
set bet_uid=gen_random_uuid()
where bet_uid is null;

alter table public.jl_aviator_bets
  alter column bet_uid set default gen_random_uuid(),
  alter column bet_uid set not null;

create unique index if not exists jl_aviator_bets_bet_uid_uidx
  on public.jl_aviator_bets(bet_uid);

create or replace function public.jl_aviator_protect_bet_uid()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
begin
  if new.bet_uid is distinct from old.bet_uid then
    raise exception 'Identificador único da aposta é imutável.';
  end if;
  return new;
end;
$function$;

drop trigger if exists jl_aviator_bet_uid_immutable
on public.jl_aviator_bets;

create trigger jl_aviator_bet_uid_immutable
before update on public.jl_aviator_bets
for each row
execute function public.jl_aviator_protect_bet_uid();

revoke all on function public.jl_aviator_protect_bet_uid()
from public,anon,authenticated;


CREATE OR REPLACE FUNCTION public.jl_aviator_public_state()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
  s record;
  v_now timestamptz:=clock_timestamp();
  v_frame_ms integer:=250;
  v_display_seq bigint;
  v_display_at timestamptz;
  v_public_status text;
  v_phase text;
  v_public_crash numeric;
  v_target numeric;
  v_exact_multiplier numeric:=1;
  v_current_multiplier numeric:=1;
  v_seconds_to_close integer;
  v_seconds_to_takeoff integer;
  v_takeoff_at timestamptz;
begin
  v_display_seq:=public.jl_aviator_display_seq(v_now,v_frame_ms);
  v_display_at:=
    timestamptz 'epoch'
    + (v_display_seq * v_frame_ms) * interval '1 millisecond';

  select enabled,maintenance_message
    into s
  from public.jl_aviator_settings
  where id=true;

  select
    id,
    round_no,
    status,
    opened_at,
    betting_closes_at,
    takeoff_at,
    locked_at,
    started_at,
    crashed_at,
    settled_at,
    crash_multiplier,
    visual_extension,
    visual_seed_commit,
    visual_seed_reveal,
    round_seed_commit,
    round_seed_reveal,
    lock_proof_commit,
    fairness_version,
    proof_published_at,
    effective_target,
    financial_ceiling,
    visual_target
  into r
  from public.jl_aviator_rounds
  order by id desc
  limit 1;

  if r.id is null then
    return jsonb_build_object(
      'server_time',v_now,
      'display_at',v_display_at,
      'display_seq',v_display_seq,
      'display_frame_ms',v_frame_ms,
      'enabled',coalesce(s.enabled,true),
      'maintenance_message',coalesce(
        s.maintenance_message,
        'Aviator em manutencao. Volte em breve.'
      ),
      'round',null
    );
  end if;

  v_public_status:=r.status;
  v_public_crash:=r.crash_multiplier;
  v_takeoff_at:=coalesce(
    r.takeoff_at,
    case
      when r.locked_at is not null then r.locked_at+interval '3 seconds'
      else null
    end
  );

  if r.status='OPEN' and r.betting_closes_at is not null then
    v_seconds_to_close:=greatest(
      0,
      ceil(extract(epoch from (r.betting_closes_at-v_display_at)))
    )::integer;
  else
    v_seconds_to_close:=null;
  end if;

  if r.status in ('OPEN','LOCKED') and v_takeoff_at is not null then
    v_seconds_to_takeoff:=greatest(
      0,
      ceil(extract(epoch from (v_takeoff_at-v_display_at)))
    )::integer;
  else
    v_seconds_to_takeoff:=null;
  end if;

  if r.status='FLYING' and r.started_at is not null then
    v_target:=coalesce(
      r.effective_target,
      r.financial_ceiling,
      r.visual_target
    );

    v_exact_multiplier:=public.jl_aviator_multiplier(r.started_at,v_now);

    if v_target is not null and v_exact_multiplier>=v_target then
      v_public_status:='CRASHED';
      v_public_crash:=v_target;
      v_current_multiplier:=v_target;
    else
      v_current_multiplier:=public.jl_aviator_multiplier(
        r.started_at,
        greatest(v_display_at,r.started_at)
      );
    end if;
  elsif r.status in ('CRASHED','SETTLED') then
    v_current_multiplier:=greatest(1,coalesce(r.crash_multiplier,1));
  else
    v_current_multiplier:=1;
  end if;

  v_phase:=case
    when v_public_status='OPEN' then 'BETTING'
    else v_public_status
  end;

  return jsonb_build_object(
    'server_time',v_now,
    'display_at',v_display_at,
    'display_seq',v_display_seq,
    'display_frame_ms',v_frame_ms,
    'enabled',coalesce(s.enabled,true),
    'maintenance_message',coalesce(
      s.maintenance_message,
      'Aviator em manutencao. Volte em breve.'
    ),
    'round',jsonb_build_object(
      'id',r.id,
      'round_no',r.round_no,
      'status',v_public_status,
      'phase',v_phase,
      'display_seq',v_display_seq,
      'display_at',v_display_at,
      'opened_at',r.opened_at,
      'betting_closes_at',r.betting_closes_at,
      'seconds_to_close',v_seconds_to_close,
      'locked_at',r.locked_at,
      'takeoff_at',v_takeoff_at,
      'seconds_to_takeoff',v_seconds_to_takeoff,
      'betting_open',
        r.status='OPEN'
        and r.betting_closes_at is not null
        and v_display_at<r.betting_closes_at,
      'started_at',r.started_at,
      'current_multiplier',v_current_multiplier,
      'crashed_at',r.crashed_at,
      'settled_at',r.settled_at,
      'crash_multiplier',v_public_crash,
      'visual_extension',r.visual_extension,
      'fairness_version',r.fairness_version,
      'round_seed_commit',coalesce(
        r.round_seed_commit,
        r.visual_seed_commit
      ),
      'lock_proof_commit',r.lock_proof_commit,
      'proof_published_at',r.proof_published_at,
      'round_seed_reveal',
        case
          when r.status in ('CRASHED','SETTLED')
            then coalesce(r.round_seed_reveal,r.visual_seed_reveal)
          else null
        end,
      'visual_seed_commit',coalesce(
        r.round_seed_commit,
        r.visual_seed_commit
      ),
      'visual_seed_reveal',
        case
          when r.status in ('CRASHED','SETTLED')
            then coalesce(r.round_seed_reveal,r.visual_seed_reveal)
          else null
        end
    )
  );
end
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_recent_results(p_limit integer DEFAULT 12)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_limit integer:=least(20,greatest(1,coalesce(p_limit,12)));
  v_results jsonb;
begin
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',q.id,
        'round_no',q.round_no,
        'crash_multiplier',q.crash_multiplier,
        'ended_at',q.ended_at
      )
      order by q.id desc
    ),
    '[]'::jsonb
  )
  into v_results
  from (
    select
      r.id,
      r.round_no,
      r.crash_multiplier,
      coalesce(r.settled_at,r.crashed_at) as ended_at
    from public.jl_aviator_rounds r
    where r.status in ('CRASHED','SETTLED')
      and r.crash_multiplier is not null
    order by r.id desc
    limit v_limit
  ) q;

  return v_results;
end
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_player_state(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
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
        'round_id',q.round_id,
        'round_no',q.round_no,
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
  values('aviator.bet_placed',jsonb_build_object('roundId',v_round.id,'roundNo',v_round.round_no,'betId',v_bet.id,'betUid',v_bet.bet_uid,'playerId',v_player_id,'stake',v_bet.stake));
  return jsonb_build_object('ok',true,'bet_id',v_bet.id,'bet_uid',v_bet.bet_uid,'round_id',v_round.id,'round_no',v_round.round_no,'stake',v_bet.stake,'balance',v_player.balance-round(p_amount,2));
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
      'roundNo',v_round.round_no,
      'betId',v_bet.id,
      'betUid',v_bet.bet_uid,
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
    'bet_uid',v_bet.bet_uid,
    'round_id',v_bet.round_id,
    'round_no',v_round.round_no,
    'transaction_id',v_tx,
    'stake',v_bet.stake,
    'auto_cashout_multiplier',v_bet.auto_cashout_multiplier,
    'balance',v_player.balance-round(p_amount,2)
  );
end
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_cashout_locked(p_bet_id bigint, p_multiplier numeric, p_cashed_out_at timestamp with time zone, p_source text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_bet public.jl_aviator_bets;
  v_round public.jl_aviator_rounds;
  v_target numeric;
  v_payout numeric;
  v_profit numeric;
  v_tx uuid;
  v_bank_after numeric;
  v_active integer;
  v_visual numeric;
  v_extension boolean;
begin
  if p_source not in ('MANUAL','AUTO') then
    raise exception 'Origem de cash-out invalida.';
  end if;

  if p_multiplier is null or p_multiplier<1 then
    raise exception 'Multiplicador de cash-out invalido.';
  end if;

  select *
    into v_bet
  from public.jl_aviator_bets
  where id=p_bet_id
  for update;

  if v_bet.id is null then
    raise exception 'Aposta nao encontrada.';
  end if;

  if v_bet.status='CASHED_OUT' then
    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'bet_id',v_bet.id,
      'bet_uid',v_bet.bet_uid,
      'round_id',v_bet.round_id,
      'round_no',(select round_no from public.jl_aviator_rounds where id=v_bet.round_id),
      'transaction_id',v_bet.payout_transaction_id,
      'source',v_bet.cashout_source,
      'multiplier',v_bet.cashout_multiplier,
      'payout',v_bet.payout
    );
  end if;

  if v_bet.status<>'ACTIVE' then
    raise exception 'Aposta ja liquidada.';
  end if;

  select *
    into v_round
  from public.jl_aviator_rounds
  where id=v_bet.round_id;

  if v_round.id is null
     or v_round.status<>'FLYING'
     or v_round.started_at is null then
    raise exception 'Voo nao esta ativo.';
  end if;

  v_target:=coalesce(
    v_round.effective_target,
    v_round.financial_ceiling,
    v_round.visual_target
  );

  if v_target is null or p_multiplier>=v_target then
    raise exception 'Crash ja atingido.';
  end if;

  if p_source='AUTO' then
    if v_bet.auto_cashout_multiplier is null
       or round(v_bet.auto_cashout_multiplier,6)<>round(p_multiplier,6) then
      raise exception 'Cash-out automatico nao corresponde ao alvo da aposta.';
    end if;
  end if;

  v_payout:=round(v_bet.stake*p_multiplier,2);
  v_profit:=greatest(0,v_payout-v_bet.stake);
  v_tx:=gen_random_uuid();

  update public.jl_aviator_bank
     set balance=round(balance-v_profit,2),
         updated_at=clock_timestamp()
   where id=true
     and balance>=v_profit
  returning balance into v_bank_after;

  if not found then
    raise exception 'Reserva da banca inconsistente.';
  end if;

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
    v_bet.player_id,
    'aviator_payout',
    v_payout,
    'completed',
    case
      when p_source='AUTO'
        then 'Auto cash-out Aviator aposta '||v_bet.id||' em '||p_multiplier||'x'
      else 'Cash-out Aviator aposta '||v_bet.id||' em '||p_multiplier||'x'
    end,
    v_bet.id,
    'PAYOUT'
  );

  update public.jl_aviator_bets
     set status='CASHED_OUT',
         cashout_multiplier=p_multiplier,
         cashout_source=p_source,
         payout=v_payout,
         cashed_out_at=p_cashed_out_at,
         payout_transaction_id=v_tx
   where id=v_bet.id
     and status='ACTIVE'
  returning * into v_bet;

  if not found then
    raise exception 'Aposta ja liquidada.';
  end if;

  update public.players
     set balance=round(balance+v_payout,2),
         updated_at=clock_timestamp()
   where id=v_bet.player_id;

  select count(*)
    into v_active
  from public.jl_aviator_bets
  where round_id=v_bet.round_id
    and status='ACTIVE';

  if v_active=0 then
    select visual_extension
      into v_extension
    from public.jl_aviator_rounds
    where id=v_bet.round_id;

    if not coalesce(v_extension,false) then
      v_visual:=public.jl_aviator_set_visual_target(
        v_bet.round_id,
        p_multiplier
      );
    end if;
  end if;

  if v_profit>0 then
    insert into public.jl_aviator_bank_ledger(
      delta,
      balance_after,
      reason,
      request_key
    )
    values(
      -v_profit,
      v_bank_after,
      case
        when p_source='AUTO'
          then 'Auto cash-out Aviator aposta '||v_bet.id
        else 'Cash-out Aviator aposta '||v_bet.id
      end,
      'cashout:'||v_bet.id
    );
  end if;

  insert into public.audit_log(action,details)
  values(
    'aviator.cashout',
    jsonb_build_object(
      'roundId',v_bet.round_id,
      'roundNo',v_round.round_no,
      'betId',v_bet.id,
      'betUid',v_bet.bet_uid,
      'playerId',v_bet.player_id,
      'transactionId',v_tx,
      'source',p_source,
      'multiplier',p_multiplier,
      'payout',v_payout,
      'bankBalanceAfter',v_bank_after,
      'visualTarget',v_visual
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
    'source',p_source,
    'multiplier',p_multiplier,
    'payout',v_payout
  );
end
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_round_proof(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  r public.jl_aviator_rounds;
  v_seed text;
  v_seed_commit text;
  v_visual numeric;
  v_payload text;
  v_lock_commit text;
  v_financial numeric;
  v_expected_final numeric;
  v_seed_ok boolean:=false;
  v_visual_ok boolean:=false;
  v_lock_ok boolean:=false;
  v_financial_ok boolean:=false;
  v_result_ok boolean:=false;
begin
  select *
    into r
  from public.jl_aviator_rounds
  where id=p_round_id;

  if not found then
    raise exception 'Rodada nao encontrada';
  end if;

  if r.status not in ('CRASHED','SETTLED') then
    return jsonb_build_object(
      'available',false,
      'round_id',r.id,
      'round_no',r.round_no,
      'status',r.status,
      'reason','proof_available_after_crash'
    );
  end if;

  if r.fairness_version<>'JL-AVIATOR-PF-v2' then
    return jsonb_build_object(
      'available',false,
      'round_id',r.id,
      'round_no',r.round_no,
      'status',r.status,
      'reason','legacy_round'
    );
  end if;

  v_seed:=coalesce(r.round_seed_reveal,r.visual_seed_reveal);

  if v_seed is not null then
    v_seed_commit:=encode(extensions.digest(v_seed,'sha256'),'hex');
    v_seed_ok:=v_seed_commit=r.round_seed_commit;
  end if;

  if r.round_seed_commit is not null then
    v_visual:=public.jl_aviator_fairness_visual_target(r.round_seed_commit);
    v_visual_ok:=round(v_visual,6)=round(r.visual_target,6);
  end if;

  v_payload:=public.jl_aviator_fairness_lock_payload(
    r.id,
    r.round_seed_commit,
    r.total_staked,
    r.financial_ceiling,
    r.visual_target,
    r.locked_effective_target
  );

  v_lock_commit:=encode(extensions.digest(v_payload,'sha256'),'hex');
  v_lock_ok:=v_lock_commit=r.lock_proof_commit;

  v_financial:=public.jl_aviator_financial_ceiling(
    r.bank_balance_snapshot,
    r.total_staked,
    r.exposure_ratio_snapshot
  );

  v_financial_ok:=case
    when r.total_staked=0 then r.financial_ceiling is null
    else round(v_financial,6)=round(r.financial_ceiling,6)
  end;

  v_expected_final:=case
    when r.visual_extension then
      greatest(
        r.visual_target,
        coalesce(r.zero_exposure_at_multiplier,r.visual_target)
      )
    else
      r.locked_effective_target
  end;

  v_result_ok:=
    v_expected_final is not null
    and r.crash_multiplier is not null
    and round(v_expected_final,6)=round(r.crash_multiplier,6);

  return jsonb_build_object(
    'available',true,
    'round_id',r.id,
    'round_no',r.round_no,
    'status',r.status,
    'fairness_version',r.fairness_version,
    'seed_commit',r.round_seed_commit,
    'seed',v_seed,
    'lock_commit',r.lock_proof_commit,
    'lock_payload',v_payload,
    'inputs',jsonb_build_object(
      'total_staked',r.total_staked,
      'financial_ceiling',r.financial_ceiling,
      'visual_target',r.visual_target,
      'locked_effective_target',r.locked_effective_target,
      'visual_extension',r.visual_extension,
      'zero_exposure_at_multiplier',r.zero_exposure_at_multiplier
    ),
    'result',jsonb_build_object(
      'expected_crash_multiplier',v_expected_final,
      'actual_crash_multiplier',r.crash_multiplier
    ),
    'checks',jsonb_build_object(
      'seed_commit_valid',v_seed_ok,
      'visual_target_valid',v_visual_ok,
      'lock_commit_valid',v_lock_ok,
      'financial_ceiling_valid',v_financial_ok,
      'result_valid',v_result_ok
    ),
    'proof_valid',
      v_seed_ok
      and v_visual_ok
      and v_lock_ok
      and v_financial_ok
      and v_result_ok,
    'published_at',r.proof_published_at
  );
end
$function$;
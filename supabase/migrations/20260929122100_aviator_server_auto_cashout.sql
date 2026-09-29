-- Aviator: cash-out automatico opcional, 100% decidido pelo servidor.
-- O jogador escolhe o multiplicador ao apostar. O navegador apenas envia
-- a preferencia; o motor liquida a aposta mesmo se o jogador ficar offline.
--
-- Regra de fronteira: auto cash-out so ganha se o seu multiplicador for
-- estritamente MENOR que o crash. Se auto == crash, o crash vence.

alter table public.jl_aviator_bets
  add column if not exists auto_cashout_multiplier numeric(18,6),
  add column if not exists cashout_source text;

alter table public.jl_aviator_bets
  drop constraint if exists jl_aviator_bets_auto_cashout_check;

alter table public.jl_aviator_bets
  add constraint jl_aviator_bets_auto_cashout_check
  check (
    auto_cashout_multiplier is null
    or auto_cashout_multiplier >= 1.01
  );

alter table public.jl_aviator_bets
  drop constraint if exists jl_aviator_bets_cashout_source_check;

alter table public.jl_aviator_bets
  add constraint jl_aviator_bets_cashout_source_check
  check (
    cashout_source is null
    or cashout_source in ('MANUAL','AUTO')
  );

update public.jl_aviator_bets
   set cashout_source='MANUAL'
 where status='CASHED_OUT'
   and cashout_source is null;

alter table public.jl_aviator_bets
  drop constraint if exists jl_aviator_bets_cashout_fields_check;

alter table public.jl_aviator_bets
  add constraint jl_aviator_bets_cashout_fields_check
  check (
    status <> 'CASHED_OUT'
    or (
      cashout_multiplier is not null
      and cashout_multiplier >= 1
      and payout is not null
      and payout >= stake
      and cashed_out_at is not null
      and payout_transaction_id is not null
      and cashout_source in ('MANUAL','AUTO')
    )
  );

create or replace function public.jl_aviator_reject_paid_cashout_mutation()
returns trigger
language plpgsql
set search_path=pg_catalog,public
as $$
begin
  if old.status='CASHED_OUT'
     and (
       new.round_id is distinct from old.round_id
       or new.player_id is distinct from old.player_id
       or new.stake is distinct from old.stake
       or new.status is distinct from old.status
       or new.auto_cashout_multiplier is distinct from old.auto_cashout_multiplier
       or new.cashout_multiplier is distinct from old.cashout_multiplier
       or new.cashout_source is distinct from old.cashout_source
       or new.payout is distinct from old.payout
       or new.cashed_out_at is distinct from old.cashed_out_at
       or new.payout_transaction_id is distinct from old.payout_transaction_id
     ) then
    raise exception 'Cash-out Aviator ja pago e imutavel.';
  end if;

  return new;
end
$$;

create or replace function public.jl_aviator_cashout_locked(
  p_bet_id bigint,
  p_multiplier numeric,
  p_cashed_out_at timestamptz,
  p_source text
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
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
    note
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
    end
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
      'betId',v_bet.id,
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
    'transaction_id',v_tx,
    'source',p_source,
    'multiplier',p_multiplier,
    'payout',v_payout
  );
end
$$;

create or replace function public.jl_aviator_cashout(
  p_token text,
  p_bet_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_probe public.jl_aviator_bets;
  v_round_id bigint;
  v_round public.jl_aviator_rounds;
  v_cashout_at timestamptz;
  v_m numeric;
begin
  select *
    into v_probe
  from public.jl_aviator_bets
  where id=p_bet_id
    and player_id=v_player_id;

  if v_probe.id is null then
    raise exception 'Aposta nao encontrada.';
  end if;

  if v_probe.status='CASHED_OUT' then
    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'bet_id',v_probe.id,
      'transaction_id',v_probe.payout_transaction_id,
      'source',v_probe.cashout_source,
      'multiplier',v_probe.cashout_multiplier,
      'payout',v_probe.payout
    );
  end if;

  perform pg_advisory_xact_lock(
    hashtext('jl_aviator_cashout_bet_'||p_bet_id::text)
  );

  select *
    into v_probe
  from public.jl_aviator_bets
  where id=p_bet_id
    and player_id=v_player_id;

  if v_probe.id is null then
    raise exception 'Aposta nao encontrada.';
  end if;

  if v_probe.status='CASHED_OUT' then
    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'bet_id',v_probe.id,
      'transaction_id',v_probe.payout_transaction_id,
      'source',v_probe.cashout_source,
      'multiplier',v_probe.cashout_multiplier,
      'payout',v_probe.payout
    );
  end if;

  if v_probe.status<>'ACTIVE' then
    raise exception 'Aposta ja liquidada.';
  end if;

  v_round_id:=v_probe.round_id;

  perform pg_advisory_xact_lock_shared(
    hashtext('jl_aviator_round_'||v_round_id::text)
  );

  select *
    into v_round
  from public.jl_aviator_rounds
  where id=v_round_id;

  select *
    into v_probe
  from public.jl_aviator_bets
  where id=p_bet_id
    and player_id=v_player_id;

  if v_probe.status='CASHED_OUT' then
    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'bet_id',v_probe.id,
      'transaction_id',v_probe.payout_transaction_id,
      'source',v_probe.cashout_source,
      'multiplier',v_probe.cashout_multiplier,
      'payout',v_probe.payout
    );
  end if;

  if v_probe.status<>'ACTIVE' then
    raise exception 'Aposta ja liquidada.';
  end if;

  if v_round.status<>'FLYING' or v_round.started_at is null then
    raise exception 'Voo nao esta ativo.';
  end if;

  v_cashout_at:=clock_timestamp();
  v_m:=public.jl_aviator_multiplier(
    v_round.started_at,
    v_cashout_at
  );

  if v_m>=coalesce(
    v_round.effective_target,
    v_round.financial_ceiling,
    v_round.visual_target
  ) then
    raise exception 'Crash ja atingido.';
  end if;

  return public.jl_aviator_cashout_locked(
    p_bet_id,
    v_m,
    v_cashout_at,
    'MANUAL'
  );
end
$$;

create or replace function public.jl_aviator_process_auto_cashouts(
  p_round_id bigint,
  p_current_multiplier numeric,
  p_processed_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  v_round public.jl_aviator_rounds;
  v_target numeric;
  v_item record;
  v_result jsonb;
  v_count integer:=0;
  v_total_payout numeric:=0;
begin
  select *
    into v_round
  from public.jl_aviator_rounds
  where id=p_round_id
  for update;

  if v_round.id is null or v_round.status<>'FLYING' then
    return jsonb_build_object(
      'processed',0,
      'total_payout',0
    );
  end if;

  v_target:=coalesce(
    v_round.effective_target,
    v_round.financial_ceiling,
    v_round.visual_target
  );

  for v_item in
    select id,auto_cashout_multiplier
    from public.jl_aviator_bets
    where round_id=p_round_id
      and status='ACTIVE'
      and auto_cashout_multiplier is not null
      and auto_cashout_multiplier<=p_current_multiplier
      and auto_cashout_multiplier<v_target
    order by auto_cashout_multiplier,id
  loop
    v_result:=public.jl_aviator_cashout_locked(
      v_item.id,
      v_item.auto_cashout_multiplier,
      p_processed_at,
      'AUTO'
    );

    if coalesce((v_result->>'already_processed')::boolean,false)=false then
      v_count:=v_count+1;
      v_total_payout:=v_total_payout+coalesce(
        (v_result->>'payout')::numeric,
        0
      );
    end if;
  end loop;

  return jsonb_build_object(
    'processed',v_count,
    'total_payout',round(v_total_payout,2)
  );
end
$$;

create or replace function public.jl_aviator_tick(p_round_id bigint)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  v public.jl_aviator_rounds;
  v_now timestamptz:=clock_timestamp();
  v_m numeric;
  v_target numeric;
  v_auto jsonb;
  v_lost numeric:=0;
  v_bank_after numeric;
begin
  perform pg_advisory_xact_lock(
    hashtext('jl_aviator_round_'||p_round_id::text)
  );

  select *
    into v
  from public.jl_aviator_rounds
  where id=p_round_id
  for update;

  if v.id is null then
    raise exception 'Rodada nao encontrada';
  end if;

  if v.status<>'FLYING' then
    return jsonb_build_object(
      'status',v.status,
      'round_id',v.id,
      'crash_multiplier',v.crash_multiplier
    );
  end if;

  v_m:=public.jl_aviator_multiplier(v.started_at,v_now);

  -- Auto cash-outs abaixo do alvo de crash acontecem matematicamente antes
  -- do crash, mesmo que este tick chegue depois dos dois limiares.
  v_auto:=public.jl_aviator_process_auto_cashouts(
    v.id,
    v_m,
    v_now
  );

  -- O ultimo cash-out pode zerar a exposicao e estender o alvo visual.
  select *
    into v
  from public.jl_aviator_rounds
  where id=p_round_id;

  v_target:=coalesce(
    v.effective_target,
    v.financial_ceiling,
    v.visual_target
  );

  if v_m<v_target then
    return jsonb_build_object(
      'status','FLYING',
      'round_id',v.id,
      'multiplier',v_m,
      'auto_cashouts',coalesce((v_auto->>'processed')::integer,0)
    );
  end if;

  update public.jl_aviator_bets
     set status='LOST',
         payout=0
   where round_id=v.id
     and status='ACTIVE';

  if not v.lost_stakes_credited then
    select coalesce(sum(stake),0)
      into v_lost
    from public.jl_aviator_bets
    where round_id=v.id
      and status='LOST';

    update public.jl_aviator_bank
       set balance=round(balance+v_lost,2),
           updated_at=clock_timestamp()
     where id=true
    returning balance into v_bank_after;

    if v_lost>0 then
      insert into public.jl_aviator_bank_ledger(
        delta,
        balance_after,
        reason,
        request_key
      )
      values(
        v_lost,
        v_bank_after,
        'Stakes perdidos Aviator rodada '||v.id,
        'lost-round:'||v.id
      );
    end if;
  end if;

  update public.jl_aviator_rounds
     set status='CRASHED',
         crashed_at=clock_timestamp(),
         crash_multiplier=v_target,
         lost_stakes_credited=true
   where id=v.id
  returning * into v;

  insert into public.audit_log(action,details)
  values(
    'aviator.crashed',
    jsonb_build_object(
      'roundId',v.id,
      'crashMultiplier',v.crash_multiplier,
      'lostStakes',v_lost,
      'autoCashouts',coalesce((v_auto->>'processed')::integer,0),
      'visualExtension',v.visual_extension
    )
  );

  return jsonb_build_object(
    'status','CRASHED',
    'round_id',v.id,
    'crash_multiplier',v.crash_multiplier,
    'auto_cashouts',coalesce((v_auto->>'processed')::integer,0)
  );
end
$$;

create or replace function public.jl_aviator_place_bet(
  p_token text,
  p_amount numeric,
  p_request_key text,
  p_auto_cashout_multiplier numeric
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_player public.players;
  v_round public.jl_aviator_rounds;
  v_bet public.jl_aviator_bets;
  v_existing public.jl_aviator_bets;
  v_enabled boolean;
  v_auto numeric;
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
    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'bet_id',v_bet.id,
      'round_id',v_bet.round_id,
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
         updated_at=now()
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

  insert into public.transactions(
    player_id,
    kind,
    amount,
    status,
    note
  )
  values(
    v_player_id,
    'aviator_bet',
    -round(p_amount,2),
    'completed',
    'Aposta Aviator rodada '||v_round.id
  );

  insert into public.audit_log(action,details)
  values(
    'aviator.bet_placed',
    jsonb_build_object(
      'roundId',v_round.id,
      'betId',v_bet.id,
      'playerId',v_player_id,
      'stake',v_bet.stake,
      'autoCashoutMultiplier',v_bet.auto_cashout_multiplier
    )
  );

  return jsonb_build_object(
    'ok',true,
    'already_processed',false,
    'bet_id',v_bet.id,
    'round_id',v_bet.round_id,
    'stake',v_bet.stake,
    'auto_cashout_multiplier',v_bet.auto_cashout_multiplier,
    'balance',v_player.balance-round(p_amount,2)
  );
end
$$;

create or replace function public.jl_aviator_place_bet(
  p_token text,
  p_amount numeric,
  p_request_key text
)
returns jsonb
language sql
security definer
set search_path=pg_catalog,public
as $$
  select public.jl_aviator_place_bet(
    p_token,
    p_amount,
    p_request_key,
    null::numeric
  );
$$;

create or replace function public.jl_aviator_player_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
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

revoke all on function public.jl_aviator_cashout_locked(
  bigint,numeric,timestamptz,text
) from public,anon,authenticated;
grant execute on function public.jl_aviator_cashout_locked(
  bigint,numeric,timestamptz,text
) to service_role;

revoke all on function public.jl_aviator_process_auto_cashouts(
  bigint,numeric,timestamptz
) from public,anon,authenticated;
grant execute on function public.jl_aviator_process_auto_cashouts(
  bigint,numeric,timestamptz
) to service_role;

revoke all on function public.jl_aviator_tick(bigint)
from public,anon,authenticated;
grant execute on function public.jl_aviator_tick(bigint)
to service_role;

revoke all on function public.jl_aviator_cashout(text,bigint) from public;
grant execute on function public.jl_aviator_cashout(text,bigint)
to anon,authenticated,service_role;

revoke all on function public.jl_aviator_place_bet(
  text,numeric,text,numeric
) from public;
grant execute on function public.jl_aviator_place_bet(
  text,numeric,text,numeric
) to anon,authenticated,service_role;

revoke all on function public.jl_aviator_place_bet(
  text,numeric,text
) from public;
grant execute on function public.jl_aviator_place_bet(
  text,numeric,text
) to anon,authenticated,service_role;

revoke all on function public.jl_aviator_player_state(text) from public;
grant execute on function public.jl_aviator_player_state(text)
to anon,authenticated,service_role;

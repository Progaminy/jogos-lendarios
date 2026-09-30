
-- Aviator: idempotencia financeira fim-a-fim.
-- Cada aposta passa a possuir no ledger no maximo um DEBITO, um PAGAMENTO
-- e um REEMBOLSO. O estado da aposta continua sendo a primeira barreira;
-- esta migration adiciona uma segunda barreira estrutural em transactions.

alter table public.transactions
  add column if not exists aviator_bet_id bigint,
  add column if not exists aviator_operation text;

-- Vincular historico existente antes de tornar o vinculo obrigatorio.
update public.transactions t
set aviator_bet_id=b.id,
    aviator_operation='PAYOUT'
from public.jl_aviator_bets b
where t.kind='aviator_payout'
  and b.payout_transaction_id=t.id
  and t.aviator_bet_id is null;

update public.transactions t
set aviator_bet_id=b.id,
    aviator_operation='REFUND'
from public.jl_aviator_bets b
where t.kind='aviator_refund'
  and b.refund_transaction_id=t.id
  and t.aviator_bet_id is null;

update public.transactions t
set aviator_bet_id=b.id,
    aviator_operation='BET'
from public.jl_aviator_bets b
where t.kind='aviator_bet'
  and t.player_id=b.player_id
  and t.note='Aposta Aviator rodada '||b.round_id::text
  and t.aviator_bet_id is null;

do $$
begin
  if not exists(
    select 1
    from pg_constraint
    where conrelid='public.transactions'::regclass
      and conname='transactions_aviator_bet_fkey'
  ) then
    alter table public.transactions
      add constraint transactions_aviator_bet_fkey
      foreign key(aviator_bet_id)
      references public.jl_aviator_bets(id)
      on delete restrict;
  end if;
end
$$;

alter table public.transactions
  drop constraint if exists transactions_aviator_operation_check;

alter table public.transactions
  add constraint transactions_aviator_operation_check
  check(
    case
      when kind='aviator_bet' then
        aviator_bet_id is not null
        and aviator_operation='BET'
        and amount<0
        and status='completed'
      when kind='aviator_payout' then
        aviator_bet_id is not null
        and aviator_operation='PAYOUT'
        and amount>0
        and status='completed'
      when kind='aviator_refund' then
        aviator_bet_id is not null
        and aviator_operation='REFUND'
        and amount>0
        and status='completed'
      else
        aviator_bet_id is null
        and aviator_operation is null
    end
  );

create unique index if not exists transactions_aviator_bet_operation_uidx
on public.transactions(aviator_bet_id,aviator_operation)
where aviator_bet_id is not null;

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

create or replace function public.jl_aviator_refund_preflight_round(
  p_round_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  v_round public.jl_aviator_rounds;
  v_bet public.jl_aviator_bets;
  v_tx uuid;
  v_count integer:=0;
  v_total numeric:=0;
  v_now timestamptz:=clock_timestamp();
begin
  select *
    into v_round
  from public.jl_aviator_rounds
  where id=p_round_id
  for update;

  if v_round.id is null then
    return jsonb_build_object(
      'ok',true,
      'round_id',p_round_id,
      'refunded_bets',0,
      'refunded_total',0,
      'already_resolved',true
    );
  end if;

  if v_round.status not in ('OPEN','LOCKED') then
    return jsonb_build_object(
      'ok',true,
      'round_id',v_round.id,
      'status',v_round.status,
      'refunded_bets',0,
      'refunded_total',0,
      'already_resolved',true
    );
  end if;

  for v_bet in
    select *
    from public.jl_aviator_bets
    where round_id=v_round.id
      and status='ACTIVE'
    order by id
    for update
  loop
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
      v_bet.player_id,
      'aviator_refund',
      v_bet.stake,
      'completed',
      'Reembolso Aviator manutenção · rodada '||
        v_round.id||' · aposta '||v_bet.id,
      v_bet.id,
      'REFUND'
    );

    update public.players
       set balance=round(balance+v_bet.stake,2),
           updated_at=v_now
     where id=v_bet.player_id;

    update public.jl_aviator_bets
       set status='REFUNDED',
           payout=v_bet.stake,
           refunded_at=v_now,
           refund_transaction_id=v_tx
     where id=v_bet.id
       and status='ACTIVE';

    if found then
      v_count:=v_count+1;
      v_total:=v_total+v_bet.stake;
    end if;
  end loop;

  update public.jl_aviator_rounds
     set status='CANCELLED',
         settled_at=coalesce(settled_at,v_now),
         next_round_at=null
   where id=v_round.id
     and status in ('OPEN','LOCKED');

  insert into public.audit_log(action,details)
  values(
    'aviator.maintenance_preflight_refunded',
    jsonb_build_object(
      'roundId',v_round.id,
      'previousStatus',v_round.status,
      'refundedBets',v_count,
      'refundedTotal',v_total,
      'resolvedAt',v_now
    )
  );

  return jsonb_build_object(
    'ok',true,
    'round_id',v_round.id,
    'previous_status',v_round.status,
    'status','CANCELLED',
    'refunded_bets',v_count,
    'refunded_total',v_total,
    'already_resolved',false
  );
end
$$;

create or replace function public.jl_aviator_admin_cancel_round(
  p_token text,
  p_round_id bigint,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  v_admin uuid;
  v_round public.jl_aviator_rounds;
  v_bet public.jl_aviator_bets;
  v_tx uuid;
  v_reason text:=btrim(coalesce(p_reason,''));
  v_now timestamptz:=clock_timestamp();
  v_refunded_bets integer:=0;
  v_refunded_total numeric:=0;
  v_cashouts integer:=0;
  v_cashout_paid numeric:=0;
  v_before_status text;
begin
  v_admin:=public.jl_admin_account_id(p_token);

  if v_admin is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  if p_round_id is null then
    raise exception 'Rodada inválida.';
  end if;

  if length(v_reason)<5 then
    raise exception 'Informe um motivo com pelo menos 5 caracteres.';
  end if;

  if length(v_reason)>240 then
    raise exception 'O motivo pode ter no máximo 240 caracteres.';
  end if;

  perform pg_advisory_xact_lock(hashtext('jl_aviator_engine_tick'));
  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));
  perform pg_advisory_xact_lock(hashtext('jl_aviator_round_'||p_round_id::text));

  select *
    into v_round
  from public.jl_aviator_rounds
  where id=p_round_id
  for update;

  if v_round.id is null then
    raise exception 'Rodada não encontrada.';
  end if;

  if v_round.status='CANCELLED'
     and v_round.admin_cancelled_at is not null then
    return jsonb_build_object(
      'ok',true,
      'already_cancelled',true,
      'round_id',v_round.id,
      'status',v_round.status,
      'reason',v_round.admin_cancel_reason,
      'refunded_bets',coalesce(v_round.admin_cancel_refunded_bets,0),
      'refunded_total',coalesce(v_round.admin_cancel_refunded_total,0)
    );
  end if;

  if v_round.status not in ('OPEN','LOCKED','FLYING') then
    raise exception
      'Esta rodada já encerrou e não pode ser cancelada administrativamente.';
  end if;

  v_before_status:=v_round.status;

  select
    count(*) filter(where status='CASHED_OUT'),
    coalesce(sum(payout) filter(where status='CASHED_OUT'),0)
    into v_cashouts,v_cashout_paid
  from public.jl_aviator_bets
  where round_id=v_round.id;

  for v_bet in
    select *
    from public.jl_aviator_bets
    where round_id=v_round.id
      and status='ACTIVE'
    order by id
    for update
  loop
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
      v_bet.player_id,
      'aviator_refund',
      v_bet.stake,
      'completed',
      left(
        'Reembolso Aviator · cancelamento administrativo · rodada '||
        v_round.id||' · aposta '||v_bet.id||' · '||v_reason,
        500
      ),
      v_bet.id,
      'REFUND'
    );

    update public.players
       set balance=round(balance+v_bet.stake,2),
           updated_at=v_now
     where id=v_bet.player_id;

    update public.jl_aviator_bets
       set status='REFUNDED',
           payout=v_bet.stake,
           refunded_at=v_now,
           refund_transaction_id=v_tx
     where id=v_bet.id
       and status='ACTIVE';

    if found then
      v_refunded_bets:=v_refunded_bets+1;
      v_refunded_total:=v_refunded_total+v_bet.stake;
    end if;
  end loop;

  update public.jl_aviator_rounds
     set status='CANCELLED',
         settled_at=coalesce(settled_at,v_now),
         next_round_at=null,
         admin_cancelled_at=v_now,
         admin_cancel_reason=v_reason,
         admin_cancelled_by=v_admin,
         admin_cancel_refunded_bets=v_refunded_bets,
         admin_cancel_refunded_total=round(v_refunded_total,2)
   where id=v_round.id
  returning * into v_round;

  insert into public.audit_log(
    action,
    details,
    actor_admin_id,
    actor_session_id,
    actor_name,
    actor_role,
    target_type,
    target_id,
    before_state,
    after_state
  )
  values(
    'aviator.round_admin_cancelled',
    jsonb_build_object(
      'roundId',v_round.id,
      'reason',v_reason,
      'refundedBets',v_refunded_bets,
      'refundedTotal',round(v_refunded_total,2),
      'cashoutsKept',v_cashouts,
      'cashoutPaidKept',v_cashout_paid,
      'cancelledAt',v_now
    ),
    v_admin,
    nullif(current_setting('jl.admin_session_id',true),'')::uuid,
    nullif(current_setting('jl.admin_name',true),''),
    nullif(current_setting('jl.admin_role',true),''),
    'aviator_round',
    v_round.id::text,
    jsonb_build_object('status',v_before_status),
    jsonb_build_object(
      'status','CANCELLED',
      'reason',v_reason,
      'refundedBets',v_refunded_bets,
      'refundedTotal',round(v_refunded_total,2)
    )
  );

  return jsonb_build_object(
    'ok',true,
    'already_cancelled',false,
    'round_id',v_round.id,
    'status','CANCELLED',
    'reason',v_reason,
    'refunded_bets',v_refunded_bets,
    'refunded_total',round(v_refunded_total,2),
    'cashouts_kept',v_cashouts,
    'cashout_paid_kept',v_cashout_paid
  );
end
$$;

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

revoke all on function public.jl_aviator_cashout_locked(
  bigint,numeric,timestamptz,text
) from public,anon,authenticated;
grant execute on function public.jl_aviator_cashout_locked(
  bigint,numeric,timestamptz,text
) to service_role;

revoke all on function public.jl_aviator_refund_preflight_round(bigint)
from public,anon,authenticated;
grant execute on function public.jl_aviator_refund_preflight_round(bigint)
to service_role;

revoke all on function public.jl_aviator_admin_cancel_round(text,bigint,text)
from public;
grant execute on function public.jl_aviator_admin_cancel_round(text,bigint,text)
to anon,authenticated;

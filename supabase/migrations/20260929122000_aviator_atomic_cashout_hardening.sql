-- Aviator: cash-out atomico e idempotente por aposta.
-- Objetivos:
-- 1) duas chamadas simultaneas da mesma aposta nunca pagam duas vezes;
-- 2) retry apos timeout retorna o mesmo resultado ja confirmado;
-- 3) bet + saldo + transacao + banca confirmam juntos ou fazem rollback juntos;
-- 4) campos financeiros de um cash-out concluido tornam-se imutaveis.

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
    )
  );

alter table public.jl_aviator_bets
  drop constraint if exists jl_aviator_bets_payout_transaction_fkey;

alter table public.jl_aviator_bets
  add constraint jl_aviator_bets_payout_transaction_fkey
  foreign key (payout_transaction_id)
  references public.transactions(id)
  on delete restrict;

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
       or new.cashout_multiplier is distinct from old.cashout_multiplier
       or new.payout is distinct from old.payout
       or new.cashed_out_at is distinct from old.cashed_out_at
       or new.payout_transaction_id is distinct from old.payout_transaction_id
     ) then
    raise exception 'Cash-out Aviator ja pago e imutavel.';
  end if;

  return new;
end
$$;

drop trigger if exists jl_aviator_paid_cashout_immutable
on public.jl_aviator_bets;

create trigger jl_aviator_paid_cashout_immutable
before update on public.jl_aviator_bets
for each row
execute function public.jl_aviator_reject_paid_cashout_mutation();

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
  v_bet public.jl_aviator_bets;
  v_round public.jl_aviator_rounds;
  v_cashout_at timestamptz;
  v_m numeric;
  v_payout numeric;
  v_profit numeric;
  v_active integer;
  v_tx uuid;
  v_bank_after numeric;
  v_visual numeric;
  v_extension boolean;
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
      'multiplier',v_probe.cashout_multiplier,
      'payout',v_probe.payout
    );
  end if;

  -- Serializa somente tentativas da MESMA aposta. Uma segunda chamada
  -- espera aqui sem segurar o lock compartilhado da rodada.
  perform pg_advisory_xact_lock(
    hashtext('jl_aviator_cashout_bet_'||p_bet_id::text)
  );

  -- Releitura obrigatoria: outra chamada pode ter concluido enquanto esta
  -- aguardava o lock por aposta.
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
      'multiplier',v_probe.cashout_multiplier,
      'payout',v_probe.payout
    );
  end if;

  v_round_id:=v_probe.round_id;

  -- Cash-outs diferentes podem coexistir; o tick/crash usa o lock exclusivo
  -- da mesma rodada e portanto nao pode ultrapassar uma decisao de cash-out
  -- ja iniciada no servidor.
  perform pg_advisory_xact_lock_shared(
    hashtext('jl_aviator_round_'||v_round_id::text)
  );

  select *
    into v_round
  from public.jl_aviator_rounds
  where id=v_round_id;

  select *
    into v_bet
  from public.jl_aviator_bets
  where id=p_bet_id
  for update;

  if v_bet.id is null
     or v_bet.player_id<>v_player_id
     or v_bet.round_id<>v_round_id then
    raise exception 'Aposta nao encontrada.';
  end if;

  if v_bet.status='CASHED_OUT' then
    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'bet_id',v_bet.id,
      'transaction_id',v_bet.payout_transaction_id,
      'multiplier',v_bet.cashout_multiplier,
      'payout',v_bet.payout
    );
  end if;

  if v_bet.status<>'ACTIVE' then
    raise exception 'Aposta ja liquidada.';
  end if;

  if v_round.status<>'FLYING' or v_round.started_at is null then
    raise exception 'Voo nao esta ativo.';
  end if;

  -- Este e o instante financeiro da decisao. Esperas posteriores por locks
  -- nao alteram o multiplicador concedido ao jogador.
  v_cashout_at:=clock_timestamp();
  v_m:=public.jl_aviator_multiplier(v_round.started_at,v_cashout_at);

  if v_m>=coalesce(
    v_round.effective_target,
    v_round.financial_ceiling,
    v_round.visual_target
  ) then
    raise exception 'Crash ja atingido.';
  end if;

  v_payout:=round(v_bet.stake*v_m,2);
  v_profit:=greatest(0,v_payout-v_bet.stake);
  v_tx:=gen_random_uuid();

  -- A banca e a secao serial financeira. Se nao houver reserva, a exception
  -- desfaz toda a transacao: nenhum saldo, payout ou movimento parcial fica.
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
    v_player_id,
    'aviator_payout',
    v_payout,
    'completed',
    'Cash-out Aviator aposta '||v_bet.id||' em '||v_m||'x'
  );

  update public.jl_aviator_bets
     set status='CASHED_OUT',
         cashout_multiplier=v_m,
         payout=v_payout,
         cashed_out_at=v_cashout_at,
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
   where id=v_player_id;

  select count(*)
    into v_active
  from public.jl_aviator_bets
  where round_id=v_round_id
    and status='ACTIVE';

  if v_active=0 then
    select visual_extension
      into v_extension
    from public.jl_aviator_rounds
    where id=v_round_id;

    if not coalesce(v_extension,false) then
      v_visual:=public.jl_aviator_set_visual_target(v_round_id,v_m);
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
      'Cash-out Aviator aposta '||v_bet.id,
      'cashout:'||v_bet.id
    );
  end if;

  insert into public.audit_log(action,details)
  values(
    'aviator.cashout',
    jsonb_build_object(
      'roundId',v_round_id,
      'betId',v_bet.id,
      'playerId',v_player_id,
      'transactionId',v_tx,
      'multiplier',v_m,
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
    'multiplier',v_m,
    'payout',v_payout
  );
end
$$;

revoke all on function public.jl_aviator_reject_paid_cashout_mutation()
from public,anon,authenticated;

revoke all on function public.jl_aviator_cashout(text,bigint) from public;
grant execute on function public.jl_aviator_cashout(text,bigint)
to anon,authenticated,service_role;

-- Aviator: cash-outs concorrentes sem serializar a rodada inteira.
-- O tick/crash mantém lock exclusivo por rodada. Cash-outs usam o mesmo
-- advisory lock em modo compartilhado e congelam o multiplicador pelo relógio
-- do servidor antes de entrar na pequena seção serial da banca.

create or replace function public.jl_aviator_cashout(
  p_token text,
  p_bet_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path=public
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
  v_tx uuid:=gen_random_uuid();
  v_bank_after numeric;
  v_visual numeric;
  v_extension boolean;
begin
  -- Retry de cash-out ja concluido pode retornar sem disputar o lock da rodada.
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
      'multiplier',v_probe.cashout_multiplier,
      'payout',v_probe.payout
    );
  end if;

  v_round_id:=v_probe.round_id;

  -- Compartilhado entre cash-outs; exclusivo no tick/crash.
  perform pg_advisory_xact_lock_shared(
    hashtext('jl_aviator_round_'||v_round_id::text)
  );

  -- Advisory lock protege a rodada contra o tick; nao precisamos bloquear
  -- a linha da rodada e, assim, cash-outs diferentes podem prosseguir juntos.
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

  -- Congela o instante da decisao no servidor. Mesmo que a banca esteja
  -- momentaneamente ocupada, o payout usa este instante, nao um tempo posterior.
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

  update public.jl_aviator_bets
     set status='CASHED_OUT',
         cashout_multiplier=v_m,
         payout=v_payout,
         cashed_out_at=v_cashout_at,
         payout_transaction_id=v_tx
   where id=v_bet.id;

  update public.players
     set balance=round(balance+v_payout,2),
         updated_at=clock_timestamp()
   where id=v_player_id;

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
    'Cash-out Aviator '||v_m||'x'
  );

  -- Pequena seção serial final. O UPDATE atomico valida a reserva e ordena
  -- os cash-outs. Depois dele, um COUNT novo enxerga cash-outs anteriores
  -- ja confirmados e identifica com seguranca o ultimo jogador ativo.
  update public.jl_aviator_bank
     set balance=round(balance-v_profit,2),
         updated_at=clock_timestamp()
   where id=true
     and balance>=v_profit
  returning balance into v_bank_after;

  if not found then
    raise exception 'Reserva da banca inconsistente.';
  end if;

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

  insert into public.audit_log(action,details)
  values(
    'aviator.cashout',
    jsonb_build_object(
      'roundId',v_round_id,
      'betId',v_bet.id,
      'multiplier',v_m,
      'payout',v_payout,
      'bankBalanceAfter',v_bank_after,
      'visualTarget',v_visual
    )
  );

  return jsonb_build_object(
    'ok',true,
    'already_processed',false,
    'multiplier',v_m,
    'payout',v_payout
  );
end
$$;

revoke all on function public.jl_aviator_cashout(text,bigint) from public;
grant execute on function public.jl_aviator_cashout(text,bigint)
to anon,authenticated,service_role;

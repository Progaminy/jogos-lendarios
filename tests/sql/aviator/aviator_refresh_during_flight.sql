-- Aviator ponto 58: refresh durante o voo.
-- Um refresh equivale a perder todo o estado local e reconstruí-lo pelo
-- jl_aviator_reconnect. O servidor deve devolver a mesma rodada FLYING,
-- a mesma aposta ACTIVE e o relógio atual, sem criar qualquer efeito financeiro.

begin;

update public.jl_aviator_rounds
   set status='CANCELLED',
       settled_at=coalesce(settled_at,clock_timestamp())
 where status in ('OPEN','LOCKED','FLYING','CRASHED');

update public.jl_aviator_settings
   set enabled=true,
       one_round_test=false,
       updated_at=clock_timestamp()
 where id=true;

update public.jl_aviator_bank
   set balance=100000,
       exposure_ratio=.5,
       updated_at=clock_timestamp()
 where id=true;

do $point58$
declare
  v_player uuid;
  v_token text:='point58-refresh-'||gen_random_uuid()::text;
  v_round bigint;
  v_bet jsonb;
  v_first jsonb;
  v_second jsonb;
  v_first_m numeric;
  v_second_m numeric;
  v_started_at timestamptz;
  v_started_after timestamptz;
  v_balance numeric;
  v_status text;
  v_active_bet jsonb;
  v_tx_count integer;
begin
  insert into public.players(name,phone,pin_hash,balance)
  values(
    'AVIATOR POINT58 REFRESH',
    'point58-'||gen_random_uuid()::text,
    'test-only',
    100
  )
  returning id into v_player;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values(
    v_player,
    public.jl_token_hash(v_token),
    clock_timestamp()+interval '1 hour'
  );

  insert into public.jl_aviator_rounds(
    status,betting_closes_at,takeoff_at
  )
  values(
    'OPEN',
    clock_timestamp()+interval '30 seconds',
    clock_timestamp()+interval '33 seconds'
  )
  returning id into v_round;

  v_bet:=public.jl_aviator_place_bet(
    v_token,
    10,
    'point58-bet-'||v_round::text
  );

  perform public.jl_aviator_lock_round(v_round);

  update public.jl_aviator_rounds
     set betting_closes_at=clock_timestamp()-interval '8 seconds',
         takeoff_at=clock_timestamp()-interval '5 seconds'
   where id=v_round;

  perform public.jl_aviator_start_round(v_round);

  update public.jl_aviator_rounds
     set started_at=clock_timestamp()-interval '8 seconds',
         financial_ceiling=10.00,
         locked_effective_target=10.00,
         effective_target=10.00,
         visual_extension=false
   where id=v_round
  returning started_at into v_started_at;

  -- Primeiro carregamento depois do refresh.
  v_first:=public.jl_aviator_reconnect(v_token);

  if (v_first->'round'->>'id')::bigint<>v_round
     or v_first->'round'->>'status'<>'FLYING' then
    raise exception 'Ponto 58: refresh não recuperou a mesma rodada FLYING: %',v_first;
  end if;

  v_first_m:=(v_first->'round'->>'current_multiplier')::numeric;

  if v_first_m<=1 then
    raise exception 'Ponto 58: refresh reiniciou multiplicador em 1x: %',v_first_m;
  end if;

  select value
    into v_active_bet
  from jsonb_array_elements(v_first->'player'->'bets')
  where (value->>'id')::bigint=(v_bet->>'bet_id')::bigint;

  if v_active_bet is null
     or v_active_bet->>'status'<>'ACTIVE'
     or (v_active_bet->>'stake')::numeric<>10 then
    raise exception 'Ponto 58: refresh perdeu/alterou a aposta ativa: %',v_active_bet;
  end if;

  perform pg_sleep(0.05);

  -- Segundo refresh da mesma página/rodada.
  v_second:=public.jl_aviator_reconnect(v_token);

  if (v_second->'round'->>'id')::bigint<>v_round
     or v_second->'round'->>'status'<>'FLYING' then
    raise exception 'Ponto 58: segundo refresh mudou a rodada: %',v_second;
  end if;

  v_second_m:=(v_second->'round'->>'current_multiplier')::numeric;

  if v_second_m<v_first_m then
    raise exception 'Ponto 58: multiplicador andou para trás após refresh: % -> %',
      v_first_m,v_second_m;
  end if;

  if (v_second->>'display_seq')::bigint<(v_first->>'display_seq')::bigint then
    raise exception 'Ponto 58: display_seq andou para trás após refresh';
  end if;

  select status into v_status
  from public.jl_aviator_bets
  where id=(v_bet->>'bet_id')::bigint;

  if v_status<>'ACTIVE' then
    raise exception 'Ponto 58: refresh liquidou ou perdeu a aposta: %',v_status;
  end if;

  select started_at into v_started_after
  from public.jl_aviator_rounds
  where id=v_round;

  if v_started_after is distinct from v_started_at then
    raise exception 'Ponto 58: refresh alterou started_at da rodada';
  end if;

  select balance into v_balance
  from public.players
  where id=v_player;

  if v_balance<>90 then
    raise exception 'Ponto 58: refresh alterou saldo do jogador: %',v_balance;
  end if;

  select count(*) into v_tx_count
  from public.transactions
  where player_id=v_player;

  if v_tx_count<>1 then
    raise exception 'Ponto 58: refresh criou transação financeira extra: %',v_tx_count;
  end if;
end
$point58$;

rollback;

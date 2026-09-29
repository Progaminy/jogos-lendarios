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

do $reconnect$
declare
  p_auto uuid;
  p_manual uuid;
  t_auto text:='aviator-reconnect-auto-'||gen_random_uuid()::text;
  t_manual text:='aviator-reconnect-manual-'||gen_random_uuid()::text;
  rid bigint;
  b_auto jsonb;
  b_manual jsonb;
  snap jsonb;
  tick jsonb;
  current_m numeric;
  bet jsonb;
begin
  insert into public.players(name,phone,pin_hash,balance)
  values('AVIATOR RECONNECT AUTO','reca-'||gen_random_uuid()::text,'x',100)
  returning id into p_auto;

  insert into public.players(name,phone,pin_hash,balance)
  values('AVIATOR RECONNECT MANUAL','recm-'||gen_random_uuid()::text,'x',100)
  returning id into p_manual;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values
    (p_auto,public.jl_token_hash(t_auto),now()+interval '1 hour'),
    (p_manual,public.jl_token_hash(t_manual),now()+interval '1 hour');

  insert into public.jl_aviator_rounds(
    status,betting_closes_at,takeoff_at
  )
  values(
    'OPEN',
    clock_timestamp()+interval '30 seconds',
    clock_timestamp()+interval '33 seconds'
  )
  returning id into rid;

  b_auto:=public.jl_aviator_place_bet(
    t_auto,10,'reconnect-auto-'||rid::text,1.20
  );

  b_manual:=public.jl_aviator_place_bet(
    t_manual,10,'reconnect-manual-'||rid::text
  );

  perform public.jl_aviator_lock_round(rid);

  update public.jl_aviator_rounds
     set betting_closes_at=clock_timestamp()-interval '8 seconds',
         takeoff_at=clock_timestamp()-interval '5 seconds'
   where id=rid;

  perform public.jl_aviator_start_round(rid);

  update public.jl_aviator_rounds
     set started_at=clock_timestamp()-interval '5 seconds',
         financial_ceiling=2.00,
         locked_effective_target=2.00,
         effective_target=2.00,
         visual_extension=false
   where id=rid;

  -- 1) Reconnect durante FLYING deve trazer o multiplicador atual do servidor
  -- e a aposta manual ainda ACTIVE, sem "reiniciar" em 1.00x.
  snap:=public.jl_aviator_reconnect(t_manual);

  if snap->'round'->>'status'<>'FLYING' then
    raise exception 'reconnect deveria ver FLYING: %',snap;
  end if;

  current_m:=(snap->'round'->>'current_multiplier')::numeric;

  if current_m<=1.20 then
    raise exception 'reconnect voltou multiplicador artificialmente baixo: %',current_m;
  end if;

  select value into bet
  from jsonb_array_elements(snap->'player'->'bets')
  where (value->>'id')::bigint=(b_manual->>'bet_id')::bigint;

  if bet->>'status'<>'ACTIVE'
     or (bet->>'stake')::numeric<>10 then
    raise exception 'reconnect nao trouxe aposta ativa correta: %',bet;
  end if;

  if (snap->>'display_seq')::bigint is null then
    raise exception 'reconnect deve trazer display_seq canonico';
  end if;

  -- 2) O motor processa auto cash-out enquanto o jogador poderia estar offline.
  tick:=public.jl_aviator_tick(rid);

  if tick->>'status'<>'FLYING'
     or (tick->>'auto_cashouts')::integer<>1 then
    raise exception 'auto cash-out deveria ocorrer durante ausencia: %',tick;
  end if;

  snap:=public.jl_aviator_reconnect(t_auto);

  select value into bet
  from jsonb_array_elements(snap->'player'->'bets')
  where (value->>'id')::bigint=(b_auto->>'bet_id')::bigint;

  if bet->>'status'<>'CASHED_OUT'
     or bet->>'cashout_source'<>'AUTO'
     or (bet->>'cashout_multiplier')::numeric<>1.20 then
    raise exception 'reconnect nao trouxe auto cash-out verdadeiro: %',bet;
  end if;

  -- 3) Depois do crash, reconnect deve mostrar CRASHED/LOST; nunca FLYING antigo.
  update public.jl_aviator_rounds
     set started_at=clock_timestamp()-interval '20 seconds',
         financial_ceiling=2.00,
         locked_effective_target=2.00,
         effective_target=2.00,
         visual_extension=false
   where id=rid;

  tick:=public.jl_aviator_tick(rid);

  if tick->>'status'<>'CRASHED' then
    raise exception 'rodada deveria crashar: %',tick;
  end if;

  snap:=public.jl_aviator_reconnect(t_manual);

  if snap->'round'->>'status'<>'CRASHED'
     or (snap->'round'->>'crash_multiplier')::numeric<>2.00 then
    raise exception 'reconnect apos crash trouxe rodada errada: %',snap;
  end if;

  select value into bet
  from jsonb_array_elements(snap->'player'->'bets')
  where (value->>'id')::bigint=(b_manual->>'bet_id')::bigint;

  if bet->>'status'<>'LOST' then
    raise exception 'reconnect apos crash deveria trazer LOST: %',bet;
  end if;
end
$reconnect$;

rollback;

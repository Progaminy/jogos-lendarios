-- Aviator pontos 65 e 66: métricas operacionais + alarme financeiro.
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

do $point65_66$
declare
  v_admin uuid;
  v_admin_token text:='obs-admin-'||gen_random_uuid()::text;
  v_player uuid;
  v_token text:='obs-player-'||gen_random_uuid()::text;
  v_round bigint;
  v_bet jsonb;
  v_obs jsonb;
  v_consistency jsonb;
begin
  insert into public.admin_accounts(display_name,role,code_hash,code_scheme,active)
  values('AVIATOR OBS TEST','admin','test-hash','bcrypt',true)
  returning id into v_admin;

  insert into public.admin_sessions(admin_id,token_hash,expires_at)
  values(v_admin,public.jl_token_hash(v_admin_token),clock_timestamp()+interval '1 hour');

  insert into public.players(name,phone,pin_hash,balance)
  values(
    'AVIATOR OBS PLAYER',
    'obs-'||gen_random_uuid()::text,
    'test-only',
    100
  )
  returning id into v_player;


  insert into public.player_sessions(player_id,token_hash,expires_at)
  values(v_player,public.jl_token_hash(v_token),clock_timestamp()+interval '1 hour');

  insert into public.jl_aviator_rounds(status,betting_closes_at,takeoff_at)
  values(
    'OPEN',
    clock_timestamp()+interval '1 minute',
    clock_timestamp()+interval '63 seconds'
  )
  returning id into v_round;

  v_bet:=public.jl_aviator_place_bet(
    v_token,10,'obs-bet-'||v_round::text,null
  );

  perform public.jl_aviator_record_client_metric(
    v_token,'BET',120,true,null,v_round,(v_bet->>'bet_id')::bigint
  );

  perform public.jl_aviator_record_client_metric(
    v_token,'CASHOUT',450,false,'ROUND_CRASHED',v_round,(v_bet->>'bet_id')::bigint
  );

  v_obs:=public.jl_aviator_admin_observability(v_admin_token);

  if (v_obs->'throughput'->>'bets_last_60s')::integer<1 then
    raise exception 'Ponto 65: métrica de apostas não apareceu: %',v_obs;
  end if;

  if (v_obs->'latency_p95_ms_15m'->>'bet')::numeric<120 then
    raise exception 'Ponto 65: p95 de latência da aposta incorreto: %',v_obs;
  end if;

  if (v_obs->'failures_15m'->>'cashout')::integer<1 then
    raise exception 'Ponto 65: falha de cash-out não foi contabilizada: %',v_obs;
  end if;

  v_consistency:=public.jl_aviator_financial_consistency_watch();

  if coalesce((v_consistency->>'ok')::boolean,false) is distinct from true then
    raise exception 'Ponto 66: fixture limpa deveria estar consistente: %',v_consistency;
  end if;

  -- Divergência deliberada: saldo materializado não coincide com ledger.
  update public.players
     set balance=balance+1
   where id=v_player;

  v_consistency:=public.jl_aviator_financial_consistency_watch();

  if coalesce((v_consistency->>'ok')::boolean,true) is distinct from false then
    raise exception 'Ponto 66: divergência financeira não foi detectada: %',v_consistency;
  end if;

  if not exists(
    select 1
    from public.jl_aviator_admin_alerts
    where alert_key='AVIATOR_FINANCIAL_MISMATCH'
      and severity='CRITICAL'
      and resolved_at is null
  ) then
    raise exception 'Ponto 66: alarme administrativo CRITICAL não foi aberto';
  end if;

  update public.players
     set balance=balance-1
   where id=v_player;

  v_consistency:=public.jl_aviator_financial_consistency_watch();

  if coalesce((v_consistency->>'ok')::boolean,false) is distinct from true then
    raise exception 'Ponto 66: consistência não voltou a OK: %',v_consistency;
  end if;

  if exists(
    select 1
    from public.jl_aviator_admin_alerts
    where alert_key='AVIATOR_FINANCIAL_MISMATCH'
      and resolved_at is null
  ) then
    raise exception 'Ponto 66: alarme não foi resolvido após correção';
  end if;
end
$point65_66$;

rollback;

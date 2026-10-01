-- Aviator ponto 62: fechamento administrativo durante uma rodada em voo.
-- Regras:
-- 1) o admin desativa imediatamente novas apostas/novas rodadas;
-- 2) uma rodada FLYING nao e cancelada nem reembolsada arbitrariamente;
-- 3) a aposta que ja esta em voo continua ACTIVE e pode fazer cash-out;
-- 4) o cash-out financeiro permanece atomico mesmo com manutencao ativa;
-- 5) a acao administrativa fica auditada.

begin;

update public.jl_aviator_rounds
   set status='CANCELLED',
       settled_at=coalesce(settled_at,clock_timestamp())
 where status in ('OPEN','LOCKED','FLYING','CRASHED');

update public.jl_aviator_settings
   set enabled=true,
       one_round_test=false,
       maintenance_message='Aviator brevemente.',
       updated_at=clock_timestamp()
 where id=true;

update public.jl_aviator_bank
   set balance=100000,
       exposure_ratio=.5,
       updated_at=clock_timestamp()
 where id=true;

do $point62$
declare
  v_admin uuid;
  v_admin_token text:='point62-admin-'||gen_random_uuid()::text;
  v_player uuid;
  v_late_player uuid;
  v_token text:='point62-player-'||gen_random_uuid()::text;
  v_late_token text:='point62-late-'||gen_random_uuid()::text;
  v_round bigint;
  v_bet jsonb;
  v_close jsonb;
  v_cashout jsonb;
  v_status text;
  v_enabled boolean;
  v_balance numeric;
  v_tx_count integer;
  v_refund_count integer;
  v_late_rejected boolean:=false;
begin
  insert into public.admin_accounts(
    display_name,role,code_hash,code_scheme,active
  )
  values(
    'AVIATOR POINT62 ADMIN','admin','test-hash','bcrypt',true
  )
  returning id into v_admin;

  insert into public.admin_sessions(admin_id,token_hash,expires_at)
  values(
    v_admin,
    public.jl_token_hash(v_admin_token),
    clock_timestamp()+interval '1 hour'
  );

  insert into public.players(name,phone,pin_hash,balance)
  values(
    'AVIATOR POINT62 PLAYER',
    'point62-player-'||gen_random_uuid()::text,
    'test-only',
    100
  )
  returning id into v_player;

  insert into public.players(name,phone,pin_hash,balance)
  values(
    'AVIATOR POINT62 LATE',
    'point62-late-'||gen_random_uuid()::text,
    'test-only',
    100
  )
  returning id into v_late_player;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values
    (
      v_player,
      public.jl_token_hash(v_token),
      clock_timestamp()+interval '1 hour'
    ),
    (
      v_late_player,
      public.jl_token_hash(v_late_token),
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
    'point62-bet-'||v_round::text,
    null
  );

  perform public.jl_aviator_lock_round(v_round);

  update public.jl_aviator_rounds
     set betting_closes_at=clock_timestamp()-interval '8 seconds',
         takeoff_at=clock_timestamp()-interval '5 seconds'
   where id=v_round;

  perform public.jl_aviator_start_round(v_round);

  -- Mantem voo longe do crash para testar o fecho administrativo em pleno voo.
  update public.jl_aviator_rounds
     set started_at=clock_timestamp()-interval '5 seconds',
         financial_ceiling=5.00,
         locked_effective_target=5.00,
         effective_target=5.00,
         visual_extension=false
   where id=v_round;

  v_close:=public.jl_aviator_admin_close(v_admin_token);

  if coalesce((v_close->>'enabled')::boolean,true) then
    raise exception 'Ponto 62: admin close nao desativou Aviator: %',v_close;
  end if;

  if coalesce((v_close->>'draining')::boolean,false) is distinct from true then
    raise exception 'Ponto 62: FLYING com aposta ativa deveria entrar em draining: %',v_close;
  end if;

  if coalesce((v_close->>'refunded_bets')::integer,0)<>0
     or coalesce((v_close->>'refunded_total')::numeric,0)<>0 then
    raise exception 'Ponto 62: FLYING nao pode ser reembolsada arbitrariamente: %',v_close;
  end if;

  select enabled into v_enabled
  from public.jl_aviator_settings
  where id=true;

  if v_enabled is distinct from false then
    raise exception 'Ponto 62: settings.enabled deveria estar false';
  end if;

  select status into v_status
  from public.jl_aviator_rounds
  where id=v_round;

  if v_status<>'FLYING' then
    raise exception 'Ponto 62: fechamento admin cancelou voo ativo: %',v_status;
  end if;

  if not exists(
    select 1
    from public.jl_aviator_bets
    where id=(v_bet->>'bet_id')::bigint
      and status='ACTIVE'
  ) then
    raise exception 'Ponto 62: aposta em voo deixou de ficar ACTIVE apos fechamento admin';
  end if;

  -- Nova aposta depois do fechamento deve falhar imediatamente.
  begin
    perform public.jl_aviator_place_bet(
      v_late_token,
      10,
      'point62-late-'||v_round::text,
      null
    );
  exception
    when others then
      if position('manutencao' in lower(sqlerrm))>0
         or position('nao ha rodada aviator aberta' in lower(sqlerrm))>0 then
        v_late_rejected:=true;
      else
        raise;
      end if;
  end;

  if not v_late_rejected then
    raise exception 'Ponto 62: nova aposta entrou depois do fechamento administrativo';
  end if;

  -- A aposta ja em voo ainda deve poder fazer cash-out.
  v_cashout:=public.jl_aviator_cashout(
    v_token,
    (v_bet->>'bet_id')::bigint,
    'point62-cashout-'||v_round::text
  );

  if coalesce((v_cashout->>'ok')::boolean,false) is distinct from true then
    raise exception 'Ponto 62: cash-out protegido falhou durante manutencao: %',v_cashout;
  end if;

  if coalesce((v_cashout->>'already_processed')::boolean,true) is distinct from false then
    raise exception 'Ponto 62: primeiro cash-out deveria processar exatamente uma vez: %',v_cashout;
  end if;

  if not exists(
    select 1
    from public.jl_aviator_bets
    where id=(v_bet->>'bet_id')::bigint
      and status='CASHED_OUT'
      and payout_transaction_id is not null
  ) then
    raise exception 'Ponto 62: aposta nao ficou CASHED_OUT';
  end if;

  select count(*) into v_tx_count
  from public.transactions
  where player_id=v_player
    and kind='aviator_payout'
    and aviator_bet_id=(v_bet->>'bet_id')::bigint
    and aviator_operation='PAYOUT';

  if v_tx_count<>1 then
    raise exception 'Ponto 62: cash-out em manutencao deveria ter 1 payout, encontrou %',v_tx_count;
  end if;

  select count(*) into v_refund_count
  from public.transactions
  where player_id=v_player
    and kind='aviator_refund'
    and aviator_bet_id=(v_bet->>'bet_id')::bigint;

  if v_refund_count<>0 then
    raise exception 'Ponto 62: aposta em voo recebeu refund indevido: %',v_refund_count;
  end if;

  select balance into v_balance
  from public.players
  where id=v_player;

  if v_balance<>round(90+(v_cashout->>'payout')::numeric,2) then
    raise exception 'Ponto 62: saldo final incoerente apos cash-out: %',v_balance;
  end if;

  if not exists(
    select 1
    from public.audit_log
    where action='aviator.maintenance_changed'
      and details->>'admin_id'=v_admin::text
      and coalesce((details->>'enabled')::boolean,true)=false
  ) then
    raise exception 'Ponto 62: fechamento administrativo nao ficou auditado';
  end if;

  -- Com manutencao ativa, nao deve nascer nova rodada.
  perform public.jl_aviator_engine_tick();

  if exists(
    select 1
    from public.jl_aviator_rounds
    where id>v_round
      and status in ('OPEN','LOCKED','FLYING')
  ) then
    raise exception 'Ponto 62: nova rodada abriu durante manutencao';
  end if;
end
$point62$;

rollback;

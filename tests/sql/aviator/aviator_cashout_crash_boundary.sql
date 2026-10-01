-- Aviator ponto 56: cash-out exatamente no instante do crash.
-- Regra financeira de fronteira:
--   cash-out < crash  => permitido
--   cash-out = crash  => rejeitado (crash vence)
--   cash-out > crash  => rejeitado
-- O teste também garante ausência de payout/saldo órfão na igualdade.

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

do $point56$
declare
  p_before uuid;
  p_equal uuid;
  p_after uuid;
  r_before bigint;
  r_equal bigint;
  r_after bigint;
  b_before bigint;
  b_equal bigint;
  b_after bigint;
  c jsonb;
  blocked boolean;
  bal numeric;
  tx_count integer;
  bet_status text;
  v_core_def text;
  v_locked_def text;
  v_core_compact text;
  v_locked_compact text;
begin
  -- Guarda estrutural do caminho público: igualdade pertence ao crash.
  select pg_get_functiondef(
    'public.jl_aviator_cashout_core(text,bigint)'::regprocedure
  )
  into v_core_def;

  select pg_get_functiondef(
    'public.jl_aviator_cashout_locked(bigint,numeric,timestamptz,text)'::regprocedure
  )
  into v_locked_def;

  v_core_compact:=regexp_replace(lower(v_core_def),'[[:space:]]+','','g');
  v_locked_compact:=regexp_replace(lower(v_locked_def),'[[:space:]]+','','g');

  if position('ifv_m>=coalesce(' in v_core_compact)=0 then
    raise exception 'Ponto 56: cash-out público não trata igualdade como crash';
  end if;

  if position('p_multiplier>=v_target' in v_locked_compact)=0 then
    raise exception 'Ponto 56: liquidador financeiro não trata igualdade como crash';
  end if;

  -- 1) Imediatamente antes do crash: deve pagar.
  insert into public.players(name,phone,pin_hash,balance)
  values(
    'AVIATOR POINT56 BEFORE',
    'p56-before-'||gen_random_uuid()::text,
    'test-only',
    90
  )
  returning id into p_before;

  insert into public.jl_aviator_rounds(
    status,betting_closes_at,takeoff_at,effective_target,financial_ceiling,visual_target
  )
  values(
    'OPEN',
    clock_timestamp()+interval '1 minute',
    clock_timestamp()+interval '63 seconds',
    2.000000,
    2.000000,
    2.000000
  )
  returning id into r_before;

  insert into public.jl_aviator_bets(
    round_id,player_id,stake,status,request_key
  )
  values(
    r_before,p_before,10,'ACTIVE',
    'point56-before-'||r_before::text
  )
  returning id into b_before;

  update public.jl_aviator_rounds
     set status='FLYING',
         started_at=clock_timestamp()-interval '1 second'
   where id=r_before;

  c:=public.jl_aviator_cashout_locked(
    b_before,
    1.999999,
    clock_timestamp(),
    'MANUAL'
  );

  if coalesce((c->>'ok')::boolean,false) is distinct from true
     or (c->>'multiplier')::numeric<>1.999999 then
    raise exception 'Ponto 56: cash-out antes do crash deveria ser pago: %',c;
  end if;

  select balance into bal
  from public.players
  where id=p_before;

  if bal<>110.00 then
    raise exception 'Ponto 56: payout antes do crash incorreto; saldo=%',bal;
  end if;

  -- 2) Exatamente no crash: deve perder. Nenhum payout pode nascer.
  insert into public.players(name,phone,pin_hash,balance)
  values(
    'AVIATOR POINT56 EQUAL',
    'p56-equal-'||gen_random_uuid()::text,
    'test-only',
    90
  )
  returning id into p_equal;

  insert into public.jl_aviator_rounds(
    status,betting_closes_at,takeoff_at,effective_target,financial_ceiling,visual_target
  )
  values(
    'OPEN',
    clock_timestamp()+interval '1 minute',
    clock_timestamp()+interval '63 seconds',
    2.000000,
    2.000000,
    2.000000
  )
  returning id into r_equal;

  insert into public.jl_aviator_bets(
    round_id,player_id,stake,status,request_key
  )
  values(
    r_equal,p_equal,10,'ACTIVE',
    'point56-equal-'||r_equal::text
  )
  returning id into b_equal;

  update public.jl_aviator_rounds
     set status='FLYING',
         started_at=clock_timestamp()-interval '1 second'
   where id=r_equal;

  blocked:=false;
  begin
    perform public.jl_aviator_cashout_locked(
      b_equal,
      2.000000,
      clock_timestamp(),
      'MANUAL'
    );
  exception
    when others then
      if position('Crash ja atingido.' in sqlerrm)>0 then
        blocked:=true;
      else
        raise;
      end if;
  end;

  if not blocked then
    raise exception 'Ponto 56: cash-out exatamente no crash foi pago';
  end if;

  select balance into bal
  from public.players
  where id=p_equal;

  if bal<>90 then
    raise exception 'Ponto 56: cash-out no crash alterou saldo: %',bal;
  end if;

  select status into bet_status
  from public.jl_aviator_bets
  where id=b_equal;

  if bet_status<>'ACTIVE' then
    raise exception 'Ponto 56: tentativa exatamente no crash liquidou parcialmente a aposta: %',
      bet_status;
  end if;

  select count(*) into tx_count
  from public.transactions
  where player_id=p_equal
    and kind='aviator_payout';

  if tx_count<>0 then
    raise exception 'Ponto 56: cash-out no crash deixou payout órfão: %',tx_count;
  end if;

  -- 3) Depois do crash: também deve ser rejeitado sem efeitos financeiros.
  insert into public.players(name,phone,pin_hash,balance)
  values(
    'AVIATOR POINT56 AFTER',
    'p56-after-'||gen_random_uuid()::text,
    'test-only',
    90
  )
  returning id into p_after;

  insert into public.jl_aviator_rounds(
    status,betting_closes_at,takeoff_at,effective_target,financial_ceiling,visual_target
  )
  values(
    'OPEN',
    clock_timestamp()+interval '1 minute',
    clock_timestamp()+interval '63 seconds',
    2.000000,
    2.000000,
    2.000000
  )
  returning id into r_after;

  insert into public.jl_aviator_bets(
    round_id,player_id,stake,status,request_key
  )
  values(
    r_after,p_after,10,'ACTIVE',
    'point56-after-'||r_after::text
  )
  returning id into b_after;

  update public.jl_aviator_rounds
     set status='FLYING',
         started_at=clock_timestamp()-interval '1 second'
   where id=r_after;

  blocked:=false;
  begin
    perform public.jl_aviator_cashout_locked(
      b_after,
      2.000001,
      clock_timestamp(),
      'MANUAL'
    );
  exception
    when others then
      if position('Crash ja atingido.' in sqlerrm)>0 then
        blocked:=true;
      else
        raise;
      end if;
  end;

  if not blocked then
    raise exception 'Ponto 56: cash-out depois do crash foi pago';
  end if;

  select balance into bal
  from public.players
  where id=p_after;

  if bal<>90 then
    raise exception 'Ponto 56: tentativa depois do crash alterou saldo: %',bal;
  end if;

  select count(*) into tx_count
  from public.transactions
  where player_id=p_after
    and kind='aviator_payout';

  if tx_count<>0 then
    raise exception 'Ponto 56: tentativa depois do crash criou payout: %',tx_count;
  end if;
end
$point56$;

rollback;

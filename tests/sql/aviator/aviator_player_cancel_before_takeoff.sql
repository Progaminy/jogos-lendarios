-- Aviator: Apostar -> Cancelar antes do fechamento, de forma atómica.
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

do $cancel_before_takeoff$
declare
  v_player uuid;
  v_token text:='cancel-before-'||gen_random_uuid()::text;
  v_round bigint;
  v_bet jsonb;
  v_cancel jsonb;
  v_retry jsonb;
  v_blocked boolean:=false;
  v_balance numeric;
  v_refunds integer;
begin
  insert into public.players(name,phone,pin_hash,balance)
  values(
    'AVIATOR CANCEL BEFORE TAKEOFF',
    'cancel-before-'||gen_random_uuid()::text,
    'test-only',
    100
  )
  returning id into v_player;

  insert into public.transactions(id,player_id,kind,amount,status,note)
  values(gen_random_uuid(),v_player,'deposit',100,'completed','Cancel test funding');

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values(
    v_player,
    public.jl_token_hash(v_token),
    clock_timestamp()+interval '1 hour'
  );

  insert into public.jl_aviator_rounds(status,betting_closes_at,takeoff_at)
  values(
    'OPEN',
    clock_timestamp()+interval '1 minute',
    clock_timestamp()+interval '63 seconds'
  )
  returning id into v_round;

  v_bet:=public.jl_aviator_place_bet(
    v_token,10,'cancel-bet-'||v_round::text,null
  );

  v_cancel:=public.jl_aviator_cancel_bet(
    v_token,
    (v_bet->>'bet_id')::bigint,
    'cancel-request-'||v_round::text
  );

  if coalesce((v_cancel->>'ok')::boolean,false) is distinct from true
     or coalesce((v_cancel->>'already_processed')::boolean,true) then
    raise exception 'cancelamento inicial falhou: %',v_cancel;
  end if;

  select balance into v_balance
  from public.players
  where id=v_player;

  if v_balance<>100 then
    raise exception 'saldo não foi restaurado: %',v_balance;
  end if;

  if not exists(
    select 1
    from public.jl_aviator_bets
    where id=(v_bet->>'bet_id')::bigint
      and status='REFUNDED'
      and payout=stake
      and refund_transaction_id is not null
  ) then
    raise exception 'aposta cancelada não ficou REFUNDED';
  end if;

  select count(*) into v_refunds
  from public.transactions
  where aviator_bet_id=(v_bet->>'bet_id')::bigint
    and aviator_operation='REFUND';

  if v_refunds<>1 then
    raise exception 'esperava um único refund, encontrou %',v_refunds;
  end if;

  v_retry:=public.jl_aviator_cancel_bet(
    v_token,
    (v_bet->>'bet_id')::bigint,
    'cancel-request-'||v_round::text
  );

  if coalesce((v_retry->>'already_processed')::boolean,false) is distinct from true then
    raise exception 'retry deveria ser idempotente: %',v_retry;
  end if;

  select count(*) into v_refunds
  from public.transactions
  where aviator_bet_id=(v_bet->>'bet_id')::bigint
    and aviator_operation='REFUND';

  if v_refunds<>1 then
    raise exception 'retry duplicou refund: %',v_refunds;
  end if;

  -- Nova aposta em nova rodada e tentativa depois do LOCKED deve falhar.
  update public.jl_aviator_rounds
     set status='CANCELLED',
         settled_at=clock_timestamp()
   where id=v_round;

  insert into public.jl_aviator_rounds(status,betting_closes_at,takeoff_at)
  values(
    'OPEN',
    clock_timestamp()+interval '1 minute',
    clock_timestamp()+interval '63 seconds'
  )
  returning id into v_round;

  v_bet:=public.jl_aviator_place_bet(
    v_token,10,'cancel-locked-'||v_round::text,null
  );

  perform public.jl_aviator_lock_round(v_round);

  begin
    perform public.jl_aviator_cancel_bet(
      v_token,
      (v_bet->>'bet_id')::bigint,
      'cancel-locked-request-'||v_round::text
    );
  exception
    when others then
      if position('Cancelamento encerrado' in sqlerrm)>0 then
        v_blocked:=true;
      else
        raise;
      end if;
  end;

  if not v_blocked then
    raise exception 'cancelamento entrou depois de LOCKED';
  end if;
end
$cancel_before_takeoff$;

rollback;

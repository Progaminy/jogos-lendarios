-- Aviator: dois slots financeiros independentes na mesma rodada.
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

do $two_slots$
declare
  v_player uuid;
  v_token text:='two-slots-'||gen_random_uuid()::text;
  v_round bigint;
  v_a jsonb;
  v_b jsonb;
  v_balance numeric;
  v_count integer;
  v_blocked boolean:=false;
  v_state jsonb;
begin
  insert into public.players(name,phone,pin_hash,balance)
  values(
    'AVIATOR TWO SLOTS',
    'two-slots-'||gen_random_uuid()::text,
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

  insert into public.jl_aviator_rounds(status,betting_closes_at,takeoff_at)
  values(
    'OPEN',
    clock_timestamp()+interval '1 minute',
    clock_timestamp()+interval '63 seconds'
  )
  returning id into v_round;

  v_a:=public.jl_aviator_place_bet_slot(
    v_token,10,'two-slot-a-'||v_round::text,null,1
  );

  v_b:=public.jl_aviator_place_bet_slot(
    v_token,20,'two-slot-b-'||v_round::text,2.00,2
  );

  if (v_a->>'bet_slot')::integer<>1
     or (v_b->>'bet_slot')::integer<>2 then
    raise exception 'slots retornados incorretamente: % / %',v_a,v_b;
  end if;

  select balance into v_balance
  from public.players
  where id=v_player;

  if v_balance<>70 then
    raise exception 'duas apostas não debitaram 30 MZN: %',v_balance;
  end if;

  select count(*) into v_count
  from public.jl_aviator_bets
  where player_id=v_player
    and round_id=v_round
    and status='ACTIVE';

  if v_count<>2 then
    raise exception 'esperava duas apostas ACTIVE, encontrou %',v_count;
  end if;

  select count(*) into v_count
  from public.transactions
  where player_id=v_player
    and aviator_operation='BET';

  if v_count<>2 then
    raise exception 'esperava duas transações BET, encontrou %',v_count;
  end if;

  begin
    perform public.jl_aviator_place_bet_slot(
      v_token,5,'two-slot-a-duplicate-'||v_round::text,null,1
    );
  exception
    when others then
      if position('Ja existe uma aposta neste painel nesta rodada' in sqlerrm)>0 then
        v_blocked:=true;
      else
        raise;
      end if;
  end;

  if not v_blocked then
    raise exception 'slot 1 aceitou segunda aposta na mesma rodada';
  end if;

  v_state:=public.jl_aviator_player_state(v_token);

  if jsonb_array_length(v_state->'bets')<2 then
    raise exception 'reconnect/player_state não devolveu os dois slots: %',v_state;
  end if;

  if not exists(
    select 1
    from jsonb_array_elements(v_state->'bets') x
    where (x->>'round_id')::bigint=v_round
      and (x->>'bet_slot')::integer=1
  ) or not exists(
    select 1
    from jsonb_array_elements(v_state->'bets') x
    where (x->>'round_id')::bigint=v_round
      and (x->>'bet_slot')::integer=2
  ) then
    raise exception 'player_state perdeu identificação dos slots: %',v_state;
  end if;
end
$two_slots$;

rollback;

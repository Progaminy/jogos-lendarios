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

do $immutable$
declare
  p uuid;
  tok text:='aviator-immutable-'||gen_random_uuid()::text;
  rid bigint;
  bet jsonb;
  bet_id bigint;
  blocked_stake boolean:=false;
  blocked_auto boolean:=false;
  blocked_key boolean:=false;
  blocked_slot boolean:=false;
  row_after public.jl_aviator_bets;
  tick jsonb;
begin
  insert into public.players(name,phone,pin_hash,balance)
  values('AVIATOR IMMUTABLE','immut-'||gen_random_uuid()::text,'x',100)
  returning id into p;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values(p,public.jl_token_hash(tok),now()+interval '1 hour');

  insert into public.jl_aviator_rounds(
    status,betting_closes_at,takeoff_at
  )
  values(
    'OPEN',
    clock_timestamp()+interval '30 seconds',
    clock_timestamp()+interval '33 seconds'
  )
  returning id into rid;

  bet:=public.jl_aviator_place_bet(
    tok,10,'immut-bet-'||rid::text,1.50
  );
  bet_id:=(bet->>'bet_id')::bigint;

  -- Mesmo antes de LOCKED, uma aposta ja confirmada nao pode mudar de termos.
  begin
    update public.jl_aviator_bets
       set stake=20
     where id=bet_id;
  exception
    when others then
      if position('Termos da aposta Aviator ja confirmada sao imutaveis.' in sqlerrm)>0 then
        blocked_stake:=true;
      else
        raise;
      end if;
  end;

  if not blocked_stake then
    raise exception 'stake confirmada pôde ser alterada';
  end if;

  begin
    update public.jl_aviator_bets
       set bet_slot=2
     where id=bet_id;
  exception
    when others then
      if position('Termos da aposta Aviator ja confirmada sao imutaveis.' in sqlerrm)>0 then
        blocked_slot:=true;
      else
        raise;
      end if;
  end;

  if not blocked_slot then
    raise exception 'bet_slot confirmado pôde ser alterado';
  end if;

  perform public.jl_aviator_lock_round(rid);

  begin
    update public.jl_aviator_bets
       set auto_cashout_multiplier=2.00
     where id=bet_id;
  exception
    when others then
      if position('Termos da aposta Aviator ja confirmada sao imutaveis.' in sqlerrm)>0 then
        blocked_auto:=true;
      else
        raise;
      end if;
  end;

  begin
    update public.jl_aviator_bets
       set request_key='mutated-after-lock'
     where id=bet_id;
  exception
    when others then
      if position('Termos da aposta Aviator ja confirmada sao imutaveis.' in sqlerrm)>0 then
        blocked_key:=true;
      else
        raise;
      end if;
  end;

  if not blocked_auto or not blocked_key then
    raise exception 'LOCKED permitiu alterar termos da aposta: auto %, key %',
      blocked_auto,blocked_key;
  end if;

  select * into row_after
  from public.jl_aviator_bets
  where id=bet_id;

  if row_after.stake<>10
     or row_after.bet_slot<>1
     or row_after.auto_cashout_multiplier<>1.50
     or row_after.request_key<>'immut-bet-'||rid::text then
    raise exception 'termos mudaram apesar do bloqueio: %',row_to_json(row_after);
  end if;

  -- Atualizacoes legitimas do motor continuam permitidas.
  update public.jl_aviator_rounds
     set betting_closes_at=clock_timestamp()-interval '4 seconds',
         takeoff_at=clock_timestamp()-interval '1 second'
   where id=rid;

  perform public.jl_aviator_start_round(rid);

  update public.jl_aviator_rounds
     set started_at=clock_timestamp()-interval '200 seconds'
   where id=rid;

  tick:=public.jl_aviator_tick(rid);

  if tick->>'status'<>'CRASHED' then
    raise exception 'motor deveria continuar podendo liquidar a aposta: %',tick;
  end if;

  select * into row_after
  from public.jl_aviator_bets
  where id=bet_id;

  if row_after.status not in ('LOST','CASHED_OUT') then
    raise exception 'motor nao atualizou status financeiro: %',row_after.status;
  end if;
end
$immutable$;

rollback;

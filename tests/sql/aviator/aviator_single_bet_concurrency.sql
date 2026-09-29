begin;

update public.jl_aviator_rounds
   set status='CANCELLED',
       settled_at=coalesce(settled_at,now())
 where status in ('OPEN','LOCKED','FLYING','CRASHED');

update public.jl_aviator_settings
   set enabled=true,
       one_round_test=false,
       updated_at=clock_timestamp()
 where id=true;

do $$
declare
  v_player uuid;
  v_token text:='aviator-single-bet-'||gen_random_uuid()::text;
  v_round bigint;
  v_first jsonb;
  v_second_blocked boolean:=false;
  v_balance numeric;
  v_bets int;
  v_tx int;
  v_def text;
begin
  insert into public.players(name,phone,pin_hash,balance)
  values(
    'AVIATOR SINGLE BET TEST',
    'single-bet-'||gen_random_uuid()::text,
    'not-a-login-pin',
    100
  )
  returning id into v_player;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values(
    v_player,
    public.jl_token_hash(v_token),
    now()+interval '1 hour'
  );

  insert into public.jl_aviator_rounds(status,betting_closes_at)
  values('OPEN',clock_timestamp()+interval '30 seconds')
  returning id into v_round;

  v_first:=public.jl_aviator_place_bet(
    v_token,
    10,
    'single-bet-request-a-'||v_round::text
  );

  begin
    perform public.jl_aviator_place_bet(
      v_token,
      20,
      'single-bet-request-b-'||v_round::text
    );
  exception
    when others then
      if position('Ja existe uma aposta nesta rodada.' in sqlerrm)>0 then
        v_second_blocked:=true;
      else
        raise;
      end if;
  end;

  if not v_second_blocked then
    raise exception 'segunda aposta do mesmo jogador/rodada deveria ser bloqueada';
  end if;

  select balance into v_balance
  from public.players
  where id=v_player;

  select count(*) into v_bets
  from public.jl_aviator_bets
  where round_id=v_round
    and player_id=v_player;

  select count(*) into v_tx
  from public.transactions
  where player_id=v_player
    and kind='aviator_bet';

  if v_balance<>90 then
    raise exception 'segunda tentativa debitou saldo: %',v_balance;
  end if;

  if v_bets<>1 or v_tx<>1 then
    raise exception 'esperava 1 aposta/1 transacao, encontrou bets %, tx %',v_bets,v_tx;
  end if;

  select pg_get_functiondef(
    'public.jl_aviator_place_bet(text,numeric,text)'::regprocedure
  )
  into v_def;

  if position('pg_advisory_xact_lock_shared' in v_def)=0 then
    raise exception 'aposta deve usar lock compartilhado de manutencao';
  end if;

  if position('for share' in lower(v_def))=0 then
    raise exception 'rodada deve ser protegida com FOR SHARE';
  end if;

  if not exists(
    select 1
    from pg_indexes
    where schemaname='public'
      and tablename='jl_aviator_bets'
      and indexname='jl_aviator_bets_player_round_uidx'
  ) then
    raise exception 'indice unico jogador/rodada ausente';
  end if;
end
$$;

rollback;

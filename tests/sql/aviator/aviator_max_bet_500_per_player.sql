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
  p1 uuid;
  p2 uuid;
  p3 uuid;
  t1 text:='aviator-max-1-'||gen_random_uuid()::text;
  t2 text:='aviator-max-2-'||gen_random_uuid()::text;
  t3 text:='aviator-max-3-'||gen_random_uuid()::text;
  rid bigint;
  b1 jsonb;
  b2 jsonb;
  blocked boolean:=false;
  direct_blocked boolean:=false;
  total numeric;
  bal3 numeric;
begin
  insert into public.players(name,phone,pin_hash,balance)
  values('AVIATOR MAX 1','max1-'||gen_random_uuid()::text,'x',2000)
  returning id into p1;

  insert into public.players(name,phone,pin_hash,balance)
  values('AVIATOR MAX 2','max2-'||gen_random_uuid()::text,'x',2000)
  returning id into p2;

  insert into public.players(name,phone,pin_hash,balance)
  values('AVIATOR MAX 3','max3-'||gen_random_uuid()::text,'x',2000)
  returning id into p3;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values
    (p1,public.jl_token_hash(t1),now()+interval '1 hour'),
    (p2,public.jl_token_hash(t2),now()+interval '1 hour'),
    (p3,public.jl_token_hash(t3),now()+interval '1 hour');

  insert into public.jl_aviator_rounds(status,betting_closes_at)
  values('OPEN',clock_timestamp()+interval '30 seconds')
  returning id into rid;

  b1:=public.jl_aviator_place_bet(
    t1,500,'max-1-request-'||rid::text
  );

  b2:=public.jl_aviator_place_bet(
    t2,500,'max-2-request-'||rid::text
  );

  if (b1->>'stake')::numeric<>500
     or (b2->>'stake')::numeric<>500 then
    raise exception '500 MZN deve ser aceite por jogador: %, %',b1,b2;
  end if;

  select coalesce(sum(stake),0)
    into total
  from public.jl_aviator_bets
  where round_id=rid;

  if total<>1000 then
    raise exception 'nao deve existir teto total de 500 MZN por rodada; total foi %',total;
  end if;

  begin
    perform public.jl_aviator_place_bet(
      t3,500.01,'max-3-request-'||rid::text
    );
  exception
    when others then
      if position('maximo 500 MZN' in sqlerrm)>0 then
        blocked:=true;
      else
        raise;
      end if;
  end;

  if not blocked then
    raise exception '500.01 MZN deveria ser rejeitado pela RPC';
  end if;

  select balance into bal3
  from public.players
  where id=p3;

  if bal3<>2000 then
    raise exception 'aposta acima de 500 debitou saldo: %',bal3;
  end if;

  begin
    insert into public.jl_aviator_bets(
      round_id,player_id,stake,request_key
    )
    values(
      rid,p3,500.01,'direct-max-bad-'||rid::text
    );
  exception
    when check_violation then
      direct_blocked:=true;
  end;

  if not direct_blocked then
    raise exception 'constraint do banco permitiu stake acima de 500 MZN';
  end if;
end
$$;

rollback;

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
  p_ok uuid;
  p_bad uuid;
  t_ok text:='aviator-min-ok-'||gen_random_uuid()::text;
  t_bad text:='aviator-min-bad-'||gen_random_uuid()::text;
  rid bigint;
  bet jsonb;
  blocked boolean:=false;
  bal_ok numeric;
  bal_bad numeric;
begin
  insert into public.players(name,phone,pin_hash,balance)
  values('AVIATOR MIN OK','min-ok-'||gen_random_uuid()::text,'x',10)
  returning id into p_ok;

  insert into public.players(name,phone,pin_hash,balance)
  values('AVIATOR MIN BAD','min-bad-'||gen_random_uuid()::text,'x',10)
  returning id into p_bad;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values
    (p_ok,public.jl_token_hash(t_ok),now()+interval '1 hour'),
    (p_bad,public.jl_token_hash(t_bad),now()+interval '1 hour');

  insert into public.jl_aviator_rounds(status,betting_closes_at)
  values('OPEN',clock_timestamp()+interval '30 seconds')
  returning id into rid;

  bet:=public.jl_aviator_place_bet(
    t_ok,0.50,'min-ok-request-'||rid::text
  );

  if (bet->>'stake')::numeric<>0.50 then
    raise exception '0.50 MZN deveria ser aceite: %',bet;
  end if;

  begin
    perform public.jl_aviator_place_bet(
      t_bad,0.49,'min-bad-request-'||rid::text
    );
  exception
    when others then
      if position('Valor de aposta invalido.' in sqlerrm)>0 then
        blocked:=true;
      else
        raise;
      end if;
  end;

  if not blocked then
    raise exception '0.49 MZN deveria ser rejeitado';
  end if;

  select balance into bal_ok from public.players where id=p_ok;
  select balance into bal_bad from public.players where id=p_bad;

  if bal_ok<>9.50 then
    raise exception 'saldo apos 0.50 incorreto: %',bal_ok;
  end if;

  if bal_bad<>10 then
    raise exception 'aposta invalida debitou saldo: %',bal_bad;
  end if;
end
$$;

rollback;

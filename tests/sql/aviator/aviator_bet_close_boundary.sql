-- Aviator ponto 55: fronteira exata do fechamento de apostas.
-- Prova permanente de três propriedades:
-- 1) antes do limite a aposta entra;
-- 2) no limite e depois dele a aposta não entra;
-- 3) se o limite for ultrapassado entre a leitura da rodada e o INSERT,
--    a exceção do trigger desfaz todo o débito/ledger da tentativa.
begin;

update public.jl_aviator_settings
   set enabled=true,
       one_round_test=false,
       updated_at=clock_timestamp()
 where id=true;

update public.jl_aviator_rounds
   set status='CANCELLED',
       settled_at=coalesce(settled_at,clock_timestamp())
 where status in ('OPEN','LOCKED','FLYING','CRASHED');

do $point55$
declare
  p_before uuid;
  p_equal uuid;
  p_race uuid;
  t_before text:='point55-before-'||gen_random_uuid()::text;
  t_equal text:='point55-equal-'||gen_random_uuid()::text;
  t_race text:='point55-race-'||gen_random_uuid()::text;
  r_before bigint;
  r_equal bigint;
  r_race bigint;
  result jsonb;
  blocked boolean;
  bal numeric;
  v_def text;
  v_compact text;
begin
  -- A regra de fronteira precisa ser inclusiva: server_now >= closes_at fecha.
  select pg_get_functiondef(p.oid)
    into v_def
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='jl_aviator_enforce_server_bet_window'
  limit 1;

  v_compact:=regexp_replace(lower(coalesce(v_def,'')),'[[:space:]]+','','g');

  if position('v_server_now>=v_closes_at' in v_compact)=0 then
    raise exception 'Ponto 55: a fronteira exata precisa rejeitar server_now >= betting_closes_at';
  end if;

  insert into public.players(name,phone,pin_hash,balance)
  values(
    'AVIATOR POINT55 BEFORE',
    'p55-before-'||gen_random_uuid()::text,
    'test-only',
    100
  )
  returning id into p_before;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values(
    p_before,
    public.jl_token_hash(t_before),
    clock_timestamp()+interval '1 hour'
  );

  insert into public.jl_aviator_rounds(
    status,betting_closes_at,takeoff_at
  )
  values(
    'OPEN',
    clock_timestamp()+interval '5 seconds',
    clock_timestamp()+interval '8 seconds'
  )
  returning id into r_before;

  result:=public.jl_aviator_place_bet(
    t_before,
    1,
    'point55-before-'||r_before::text
  );

  if coalesce((result->>'ok')::boolean,false) is distinct from true
     or (result->>'round_id')::bigint<>r_before then
    raise exception 'Ponto 55: aposta antes do limite deveria ser aceita: %',result;
  end if;

  update public.jl_aviator_rounds
     set status='CANCELLED',
         settled_at=clock_timestamp()
   where id=r_before;

  -- No instante de fechamento, a rodada já está fechada para novas apostas.
  insert into public.players(name,phone,pin_hash,balance)
  values(
    'AVIATOR POINT55 EQUAL',
    'p55-equal-'||gen_random_uuid()::text,
    'test-only',
    100
  )
  returning id into p_equal;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values(
    p_equal,
    public.jl_token_hash(t_equal),
    clock_timestamp()+interval '1 hour'
  );

  insert into public.jl_aviator_rounds(
    status,betting_closes_at,takeoff_at
  )
  values(
    'OPEN',
    clock_timestamp(),
    clock_timestamp()+interval '3 seconds'
  )
  returning id into r_equal;

  blocked:=false;
  begin
    perform public.jl_aviator_place_bet(
      t_equal,
      1,
      'point55-equal-'||r_equal::text
    );
  exception
    when others then
      if position('Nao ha rodada Aviator aberta.' in sqlerrm)>0
         or position('Apostas fechadas pelo relogio do servidor.' in sqlerrm)>0 then
        blocked:=true;
      else
        raise;
      end if;
  end;

  if not blocked then
    raise exception 'Ponto 55: aposta exatamente no fechamento foi aceita';
  end if;

  select balance into bal
  from public.players
  where id=p_equal;

  if bal<>100 then
    raise exception 'Ponto 55: tentativa no limite alterou saldo: %',bal;
  end if;

  if exists(
    select 1
    from public.jl_aviator_bets
    where player_id=p_equal
      and request_key='point55-equal-'||r_equal::text
  ) then
    raise exception 'Ponto 55: tentativa no limite deixou aposta registrada';
  end if;

  update public.jl_aviator_rounds
     set status='CANCELLED',
         settled_at=clock_timestamp()
   where id=r_equal;

  -- Corrida real: a RPC recebe a aposta antes do fechamento, mas o fechamento
  -- acontece durante o débito. O trigger do INSERT deve rejeitar e o PostgreSQL
  -- precisa desfazer o débito e qualquer efeito financeiro da tentativa.
  insert into public.players(name,phone,pin_hash,balance)
  values(
    'AVIATOR POINT55 RACE',
    'p55-race-'||gen_random_uuid()::text,
    'test-only',
    100
  )
  returning id into p_race;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values(
    p_race,
    public.jl_token_hash(t_race),
    clock_timestamp()+interval '1 hour'
  );

  insert into public.jl_aviator_rounds(
    status,betting_closes_at,takeoff_at
  )
  values(
    'OPEN',
    clock_timestamp()+interval '2 seconds',
    clock_timestamp()+interval '5 seconds'
  )
  returning id into r_race;

  create or replace function public.jl_point55_delay_wallet_update()
  returns trigger
  language plpgsql
  set search_path to 'pg_catalog','public'
  as $delay$
  begin
    if old.name='AVIATOR POINT55 RACE' then
      perform pg_sleep(3);
    end if;
    return new;
  end;
  $delay$;

  create trigger jl_point55_delay_wallet_update
  before update on public.players
  for each row
  execute function public.jl_point55_delay_wallet_update();

  blocked:=false;
  begin
    perform public.jl_aviator_place_bet(
      t_race,
      10,
      'point55-race-'||r_race::text
    );
  exception
    when others then
      if position('Apostas fechadas pelo relogio do servidor.' in sqlerrm)>0 then
        blocked:=true;
      else
        raise;
      end if;
  end;

  drop trigger jl_point55_delay_wallet_update on public.players;
  drop function public.jl_point55_delay_wallet_update();

  if not blocked then
    raise exception 'Ponto 55: corrida fechamento x INSERT não foi bloqueada';
  end if;

  select balance into bal
  from public.players
  where id=p_race;

  if bal<>100 then
    raise exception 'Ponto 55: corrida deixou débito órfão; saldo=%',bal;
  end if;

  if exists(
    select 1
    from public.jl_aviator_bets
    where player_id=p_race
      and request_key='point55-race-'||r_race::text
  ) then
    raise exception 'Ponto 55: corrida deixou aposta registrada';
  end if;

  if exists(
    select 1
    from public.transactions
    where player_id=p_race
      and kind='aviator_bet'
      and note='Aposta Aviator rodada '||r_race::text
  ) then
    raise exception 'Ponto 55: corrida deixou lançamento financeiro órfão';
  end if;
end
$point55$;

rollback;

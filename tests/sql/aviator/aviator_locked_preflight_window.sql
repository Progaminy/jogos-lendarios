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

do $locktest$
declare
  p1 uuid;
  p2 uuid;
  t1 text:='aviator-lock-p1-'||gen_random_uuid()::text;
  t2 text:='aviator-lock-p2-'||gen_random_uuid()::text;
  opened jsonb;
  tick jsonb;
  state jsonb;
  rid bigint;
  r public.jl_aviator_rounds;
  bet jsonb;
  blocked boolean:=false;
  bal2 numeric;
  gap_seconds numeric;
begin
  opened:=public.jl_aviator_open_next_if_due();

  if coalesce((opened->>'opened')::boolean,false) is not true then
    raise exception 'engine deveria abrir uma rodada de teste: %',opened;
  end if;

  rid:=(opened->>'round_id')::bigint;

  select * into r
  from public.jl_aviator_rounds
  where id=rid;

  if r.status<>'OPEN' then
    raise exception 'rodada nova deve iniciar internamente OPEN/BETTING: %',r.status;
  end if;

  if r.takeoff_at is not null then
    raise exception 'descolagem nao deve ser pre-agendada antes de 0: %',r.takeoff_at;
  end if;

  state:=public.jl_aviator_public_state();

  if state->'round'->>'phase'<>'BETTING' then
    raise exception 'fase publica inicial deveria ser BETTING: %',state;
  end if;

  insert into public.players(name,phone,pin_hash,balance)
  values('AVIATOR LOCK P1','lock-p1-'||gen_random_uuid()::text,'x',100)
  returning id into p1;

  insert into public.players(name,phone,pin_hash,balance)
  values('AVIATOR LOCK P2','lock-p2-'||gen_random_uuid()::text,'x',100)
  returning id into p2;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values
    (p1,public.jl_token_hash(t1),now()+interval '1 hour'),
    (p2,public.jl_token_hash(t2),now()+interval '1 hour');

  bet:=public.jl_aviator_place_bet(
    t1,10,'locked-window-p1-'||rid::text
  );

  if (bet->>'stake')::numeric<>10 then
    raise exception 'aposta em BETTING deveria entrar: %',bet;
  end if;

  update public.jl_aviator_rounds
     set betting_closes_at=clock_timestamp()-interval '5 seconds',
         takeoff_at=null,
         engine_due_at=clock_timestamp()-interval '1 millisecond'
   where id=rid;

  tick:=public.jl_aviator_engine_tick();

  if tick->>'action'<>'LOCKED' then
    raise exception 'primeiro tick apos fecho deve apenas LOCK, nao voar: %',tick;
  end if;

  select * into r
  from public.jl_aviator_rounds
  where id=rid;

  if r.status<>'LOCKED' or r.started_at is not null then
    raise exception 'LOCKED nao pode ter voo iniciado: status %, started_at %',
      r.status,r.started_at;
  end if;

  state:=public.jl_aviator_public_state();

  if state->'round'->>'phase'<>'LOCKED' then
    raise exception 'fase publica deveria ser LOCKED: %',state;
  end if;

  begin
    perform public.jl_aviator_place_bet(
      t2,10,'locked-window-p2-'||rid::text
    );
  exception
    when others then
      if position('Nao ha rodada Aviator aberta.' in sqlerrm)>0 then
        blocked:=true;
      else
        raise;
      end if;
  end;

  if not blocked then
    raise exception 'nova aposta entrou durante LOCKED';
  end if;

  select balance into bal2
  from public.players
  where id=p2;

  if bal2<>100 then
    raise exception 'aposta bloqueada em LOCKED alterou saldo: %',bal2;
  end if;

  tick:=public.jl_aviator_engine_tick();

  if tick->>'action'<>'WAIT_LOCKED' then
    raise exception 'engine nao deveria descolar durante janela segura: %',tick;
  end if;

  update public.jl_aviator_rounds
     set locked_at=clock_timestamp()-interval '4 seconds',
         engine_due_at=clock_timestamp()-interval '1 millisecond'
   where id=rid;

  tick:=public.jl_aviator_engine_tick();

  if tick->>'action'<>'STARTED'
     or tick->>'status'<>'FLYING' then
    raise exception 'engine deveria iniciar FLYING apos takeoff_at: %',tick;
  end if;

  select * into r
  from public.jl_aviator_rounds
  where id=rid;

  if r.status<>'FLYING' or r.started_at is null then
    raise exception 'rodada nao iniciou voo corretamente';
  end if;

  state:=public.jl_aviator_public_state();

  if state->'round'->>'phase'<>'FLYING' then
    raise exception 'fase publica deveria ser FLYING: %',state;
  end if;

  -- Forca o alvo a 1x apenas dentro desta transacao de teste para provar
  -- que CRASHED e SETTLED sao commits/ticks distintos.
  update public.jl_aviator_rounds
     set effective_target=1,
         started_at=clock_timestamp()-interval '1 second'
   where id=rid;

  tick:=public.jl_aviator_engine_tick();

  if tick->>'status'<>'CRASHED'
     or tick->>'phase'<>'CRASHED' then
    raise exception 'primeiro tick do crash deveria permanecer CRASHED: %',tick;
  end if;

  select * into r
  from public.jl_aviator_rounds
  where id=rid;

  if r.status<>'CRASHED' or r.settled_at is not null then
    raise exception 'CRASHED precisa ficar commitado antes de SETTLED';
  end if;

  state:=public.jl_aviator_public_state();

  if state->'round'->>'phase'<>'CRASHED' then
    raise exception 'fase publica deveria expor CRASHED: %',state;
  end if;

  tick:=public.jl_aviator_engine_tick();

  if tick->>'status'<>'SETTLED'
     or tick->>'phase'<>'SETTLED' then
    raise exception 'tick seguinte deveria liquidar SETTLED: %',tick;
  end if;

  select * into r
  from public.jl_aviator_rounds
  where id=rid;

  if r.status<>'SETTLED' or r.settled_at is null then
    raise exception 'rodada deveria terminar SETTLED';
  end if;
end
$locktest$;

rollback;

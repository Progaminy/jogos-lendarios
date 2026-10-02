-- Ponto 52: histórico pessoal isolado do histórico global e de outros jogadores.
begin;

update public.jl_aviator_settings
   set enabled=false,
       one_round_test=false
 where id=true;

update public.jl_aviator_rounds
   set status='CANCELLED',
       settled_at=coalesce(settled_at,clock_timestamp())
 where status in ('OPEN','LOCKED','FLYING','CRASHED');

do $test$
declare
  v_p1 uuid;
  v_p2 uuid;
  v_round bigint;
  v_b1 bigint;
  v_b2 bigint;
  v_token1 text:='aviator_history_test_a_20260930';
  v_token2 text:='aviator_history_test_b_20260930';
  v_result jsonb;
  v_bets jsonb;
  v_def text;
  v_public_exec boolean;
begin
  insert into public.players(name,phone,pin_hash,balance)
  values('History A','9900520001','test-only',0)
  returning id into v_p1;

  insert into public.players(name,phone,pin_hash,balance)
  values('History B','9900520002','test-only',0)
  returning id into v_p2;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values
    (v_p1,public.jl_token_hash(v_token1),clock_timestamp()+interval '1 hour'),
    (v_p2,public.jl_token_hash(v_token2),clock_timestamp()+interval '1 hour');

  insert into public.jl_aviator_rounds(status,betting_closes_at,takeoff_at)
  values(
    'OPEN',
    clock_timestamp()+interval '10 minutes',
    clock_timestamp()+interval '10 minutes 3 seconds'
  )
  returning id into v_round;

  insert into public.jl_aviator_bets(round_id,player_id,stake,status,request_key)
  values(v_round,v_p1,10,'ACTIVE','history-test-a')
  returning id into v_b1;

  insert into public.jl_aviator_bets(round_id,player_id,stake,status,request_key)
  values(v_round,v_p2,20,'ACTIVE','history-test-b')
  returning id into v_b2;

  v_result:=public.jl_aviator_my_history(v_token1,20,null);
  v_bets:=coalesce(v_result->'bets','[]'::jsonb);

  if coalesce((v_result->>'ok')::boolean,false) is not true then
    raise exception 'historico pessoal não retornou ok';
  end if;

  if jsonb_array_length(v_bets)<>1 then
    raise exception 'token A recebeu quantidade inesperada de apostas: %',jsonb_array_length(v_bets);
  end if;

  if (v_bets->0->>'id')::bigint<>v_b1 then
    raise exception 'token A não recebeu sua própria aposta';
  end if;

  if coalesce((v_bets->0->>'bet_slot')::integer,0)<>1 then
    raise exception 'historico pessoal não expõe bet_slot da aposta';
  end if;

  if exists(
    select 1
    from jsonb_array_elements(v_bets) x
    where (x->>'id')::bigint=v_b2
  ) then
    raise exception 'vazamento: token A recebeu aposta do jogador B';
  end if;

  select pg_get_functiondef(p.oid)
  into v_def
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='jl_aviator_my_history'
    and pg_get_function_identity_arguments(p.oid)='p_token text, p_limit integer, p_before_id bigint';

  if position('b.player_id=v_player' in lower(v_def))=0 then
    raise exception 'filtro de ownership ausente';
  end if;

  if position('b.id<p_before_id' in lower(v_def))=0 then
    raise exception 'paginação por bet_id ausente';
  end if;

  if position('jl_player_ledger_balance' in lower(v_def))>0 then
    raise exception 'historico pessoal voltou a agregar ledger/saldo';
  end if;

  select exists(
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    cross join lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
    where n.nspname='public'
      and p.proname='jl_aviator_my_history'
      and pg_get_function_identity_arguments(p.oid)='p_token text, p_limit integer, p_before_id bigint'
      and a.grantee=0
      and a.privilege_type='EXECUTE'
  )
  into v_public_exec;

  if v_public_exec then
    raise exception 'PUBLIC ainda possui EXECUTE direto';
  end if;

  if not has_function_privilege(
    'anon',
    'public.jl_aviator_my_history(text,integer,bigint)',
    'EXECUTE'
  ) then
    raise exception 'anon sem EXECUTE para RPC autenticado por token';
  end if;
end
$test$;

rollback;

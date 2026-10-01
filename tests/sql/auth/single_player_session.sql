-- Regression: exactly one player session survives and the latest successful login wins.
begin;

do $test$
declare
  v_player uuid;
  v_token_1 text := encode(extensions.gen_random_bytes(32),'hex');
  v_token_2 text := encode(extensions.gen_random_bytes(32),'hex');
  v_count integer;
  v_remaining_hash text;
  v_old_rejected boolean := false;
begin
  if not exists (
    select 1
    from pg_indexes
    where schemaname='public'
      and tablename='player_sessions'
      and indexname='player_sessions_single_player_uq'
      and indexdef ilike 'create unique index%'
  ) then
    raise exception 'single-player unique session index is missing';
  end if;

  if not exists (
    select 1
    from pg_trigger t
    join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relname='player_sessions'
      and t.tgname='player_sessions_single_session_guard'
      and not t.tgisinternal
  ) then
    raise exception 'single-player session guard trigger is missing';
  end if;

  if has_function_privilege(
    'anon',
    'public.jl_guard_single_player_session()',
    'EXECUTE'
  ) or has_function_privilege(
    'authenticated',
    'public.jl_guard_single_player_session()',
    'EXECUTE'
  ) then
    raise exception 'session guard trigger function is directly executable by browser roles';
  end if;

  insert into public.players(name,phone,pin_hash)
  values(
    'CI Session Test',
    '__ci_session_' || replace(gen_random_uuid()::text,'-',''),
    extensions.crypt('1234',extensions.gen_salt('bf'))
  )
  returning id into v_player;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values(
    v_player,
    public.jl_token_hash(v_token_1),
    now()+interval '1 hour'
  );

  if public.jl_player_id(v_token_1)<>v_player then
    raise exception 'first session did not validate';
  end if;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values(
    v_player,
    public.jl_token_hash(v_token_2),
    now()+interval '1 hour'
  );

  select count(*),max(token_hash)
  into v_count,v_remaining_hash
  from public.player_sessions
  where player_id=v_player
    and expires_at>now();

  if v_count<>1 then
    raise exception 'expected exactly one active session after replacement, found %',v_count;
  end if;

  if v_remaining_hash<>public.jl_token_hash(v_token_2) then
    raise exception 'latest login did not replace the previous session';
  end if;

  begin
    perform public.jl_player_id(v_token_1);
  exception
    when others then
      if sqlerrm='Sessão do jogador inválida ou expirada.' then
        v_old_rejected:=true;
      else
        raise;
      end if;
  end;

  if not v_old_rejected then
    raise exception 'previous token still validates after latest login';
  end if;

  if public.jl_player_id(v_token_2)<>v_player then
    raise exception 'latest token did not validate';
  end if;
end
$test$;

rollback;

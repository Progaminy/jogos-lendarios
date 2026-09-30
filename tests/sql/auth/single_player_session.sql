-- Regression: a player account can never have two active sessions at once.
begin;

do $test$
declare
  v_player uuid;
  v_blocked boolean:=false;
  v_count integer;
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

  select id into v_player
  from public.players
  order by id
  limit 1;

  if v_player is null then
    raise exception 'test requires at least one player';
  end if;

  delete from public.player_sessions
  where player_id=v_player;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values(
    v_player,
    md5(random()::text||clock_timestamp()::text),
    now()+interval '1 hour'
  );

  begin
    insert into public.player_sessions(player_id,token_hash,expires_at)
    values(
      v_player,
      md5(random()::text||clock_timestamp()::text),
      now()+interval '1 hour'
    );
  exception
    when others then
      if sqlerrm='Esta conta já está ligada noutro dispositivo.' then
        v_blocked:=true;
      else
        raise;
      end if;
  end;

  if not v_blocked then
    raise exception 'second active session was accepted';
  end if;

  select count(*) into v_count
  from public.player_sessions
  where player_id=v_player
    and expires_at>now();

  if v_count<>1 then
    raise exception 'expected exactly one active session, found %',v_count;
  end if;

  delete from public.player_sessions
  where player_id=v_player;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values(
    v_player,
    md5(random()::text||clock_timestamp()::text),
    now()-interval '1 minute'
  );

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values(
    v_player,
    md5(random()::text||clock_timestamp()::text),
    now()+interval '1 hour'
  );

  select count(*) into v_count
  from public.player_sessions
  where player_id=v_player;

  if v_count<>1 then
    raise exception 'expired session was not replaced cleanly';
  end if;
end
$test$;

rollback;

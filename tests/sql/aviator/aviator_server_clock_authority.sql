-- Ponto 37: relógio do servidor é autoridade da janela de apostas.
begin;

do $test$
declare
  v_round_id bigint;
  v_player uuid;
  v_created timestamptz;
  v_before timestamptz:=clock_timestamp();
  v_blocked boolean:=false;
  v_def text;
begin
  if not exists(
    select 1
    from pg_trigger t
    join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relname='jl_aviator_bets'
      and t.tgname='jl_aviator_server_bet_window'
      and not t.tgisinternal
  ) then
    raise exception 'trigger de janela de aposta ausente';
  end if;

  select pg_get_functiondef(p.oid)
  into v_def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='jl_aviator_enforce_server_bet_window';

  if position('clock_timestamp()' in v_def)=0
     or position('new.created_at:=v_server_now' in lower(v_def))=0 then
    raise exception 'gate não usa relógio do servidor';
  end if;

  if (
    select column_default
    from information_schema.columns
    where table_schema='public'
      and table_name='jl_aviator_bets'
      and column_name='created_at'
  )<>'clock_timestamp()' then
    raise exception 'created_at não usa clock_timestamp()';
  end if;

  select id into v_player
  from public.players
  order by id
  limit 1;

  insert into public.jl_aviator_rounds(status,betting_closes_at,takeoff_at)
  values(
    'OPEN',
    clock_timestamp()+interval '1 minute',
    clock_timestamp()+interval '2 minutes'
  )
  returning id into v_round_id;

  insert into public.jl_aviator_bets(
    round_id,player_id,stake,created_at,request_key
  )
  values(
    v_round_id,v_player,1,
    timestamptz '2000-01-01 00:00:00+00',
    'point37-forged-time'
  )
  returning created_at into v_created;

  if v_created<v_before then
    raise exception 'created_at do cliente foi aceito';
  end if;

  delete from public.jl_aviator_bets where round_id=v_round_id;

  update public.jl_aviator_rounds
  set betting_closes_at=clock_timestamp()-interval '1 millisecond'
  where id=v_round_id;

  begin
    insert into public.jl_aviator_bets(
      round_id,player_id,stake,created_at,request_key
    )
    values(
      v_round_id,v_player,1,
      timestamptz '1999-01-01 00:00:00+00',
      'point37-after-close'
    );
  exception
    when others then
      if position('Apostas fechadas pelo relogio do servidor' in sqlerrm)>0 then
        v_blocked:=true;
      else
        raise;
      end if;
  end;

  if not v_blocked then
    raise exception 'aposta depois do fecho foi aceita';
  end if;

  if has_table_privilege('anon','public.jl_aviator_bets','INSERT')
     or has_table_privilege('authenticated','public.jl_aviator_bets','INSERT') then
    raise exception 'cliente possui INSERT direto em jl_aviator_bets';
  end if;

  if exists(
    select 1
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='jl_aviator_place_bet'
      and pg_get_function_identity_arguments(p.oid) ilike '%timestamp%'
  ) then
    raise exception 'endpoint público de aposta aceita timestamp do cliente';
  end if;
end
$test$;

rollback;

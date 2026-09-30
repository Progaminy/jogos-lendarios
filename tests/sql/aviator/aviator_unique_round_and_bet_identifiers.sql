-- Ponto 31: número único por rodada e UUID único por aposta.
begin;

do $test$
declare
  v_bet_id bigint;
  v_blocked boolean:=false;
  v_public jsonb;
begin
  if (
    select is_generated
    from information_schema.columns
    where table_schema='public'
      and table_name='jl_aviator_rounds'
      and column_name='round_no'
  )<>'ALWAYS' then
    raise exception 'round_no não é GENERATED ALWAYS';
  end if;

  if exists(
    select round_no
    from public.jl_aviator_rounds
    group by round_no
    having count(*)>1
  ) then
    raise exception 'round_no duplicado';
  end if;

  if exists(
    select 1 from public.jl_aviator_rounds where round_no is null
  ) then
    raise exception 'round_no nulo';
  end if;

  if exists(
    select 1 from public.jl_aviator_rounds where round_no<>id
  ) then
    raise exception 'round_no divergente do identificador interno';
  end if;

  if exists(
    select 1 from public.jl_aviator_bets where bet_uid is null
  ) then
    raise exception 'bet_uid nulo';
  end if;

  if exists(
    select bet_uid
    from public.jl_aviator_bets
    group by bet_uid
    having count(*)>1
  ) then
    raise exception 'bet_uid duplicado';
  end if;

  if not exists(
    select 1
    from pg_indexes
    where schemaname='public'
      and indexname='jl_aviator_rounds_round_no_uidx'
      and indexdef ilike 'CREATE UNIQUE INDEX%'
  ) then
    raise exception 'índice único de round_no ausente';
  end if;

  if not exists(
    select 1
    from pg_indexes
    where schemaname='public'
      and indexname='jl_aviator_bets_bet_uid_uidx'
      and indexdef ilike 'CREATE UNIQUE INDEX%'
  ) then
    raise exception 'índice único de bet_uid ausente';
  end if;

  select id into v_bet_id
  from public.jl_aviator_bets
  order by id
  limit 1;

  if v_bet_id is not null then
    begin
      update public.jl_aviator_bets
      set bet_uid=gen_random_uuid()
      where id=v_bet_id;
    exception
      when others then
        if position('Identificador único da aposta é imutável' in sqlerrm)>0 then
          v_blocked:=true;
        else
          raise;
        end if;
    end;

    if not v_blocked then
      raise exception 'bet_uid aceitou alteração';
    end if;
  end if;

  v_public:=public.jl_aviator_public_state();
  if v_public->'round' is not null
     and not ((v_public->'round') ? 'round_no') then
    raise exception 'estado público não expõe round_no';
  end if;

  if not exists(
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='jl_aviator_player_state'
      and position('bet_uid' in pg_get_functiondef(p.oid))>0
      and position('round_no' in pg_get_functiondef(p.oid))>0
  ) then
    raise exception 'player state não expõe bet_uid + round_no';
  end if;
end
$test$;

rollback;

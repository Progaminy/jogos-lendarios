-- Ponto 33: rate limiting em aposta, cash-out, reconnect e administração.
begin;

do $test$
declare
  v_blocked boolean:=false;
begin
  if to_regclass('public.jl_api_rate_limits') is null then
    raise exception 'jl_api_rate_limits ausente';
  end if;

  if not exists(
    select 1
    from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relname='jl_api_rate_limits'
      and c.relrowsecurity
  ) then
    raise exception 'RLS não está ativo no rate limiter';
  end if;

  if has_function_privilege(
       'anon',
       'public.jl_rate_limit_enforce(text,text,integer,integer,integer,integer)',
       'EXECUTE'
     )
     or has_function_privilege(
       'authenticated',
       'public.jl_rate_limit_enforce(text,text,integer,integer,integer,integer)',
       'EXECUTE'
     ) then
    raise exception 'helper genérico de rate limit exposto ao cliente';
  end if;

  if not has_function_privilege(
    'anon',
    'public.jl_aviator_reconnect_rate_limit(text)',
    'EXECUTE'
  ) then
    raise exception 'bridge seguro de reconnect não está disponível ao cliente';
  end if;

  if has_table_privilege('service_role','public.jl_api_rate_limits','INSERT')
     or has_table_privilege('service_role','public.jl_api_rate_limits','UPDATE')
     or has_table_privilege('service_role','public.jl_api_rate_limits','DELETE') then
    raise exception 'service_role possui escrita direta no rate limiter';
  end if;

  if not exists(
    select 1
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='jl_aviator_place_bet'
      and pg_get_function_identity_arguments(p.oid)=
          'p_token text, p_amount numeric, p_request_key text, p_auto_cashout_multiplier numeric'
      and position('jl_rate_limit_enforce' in pg_get_functiondef(p.oid))>0
  ) then
    raise exception 'aposta Aviator sem rate limit';
  end if;

  if not exists(
    select 1
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='jl_aviator_cashout'
      and pg_get_function_identity_arguments(p.oid)=
          'p_token text, p_bet_id bigint, p_request_key text'
      and position('jl_rate_limit_hit' in pg_get_functiondef(p.oid))>0
      and position('aviator_cashout_token:burst' in pg_get_functiondef(p.oid))>0
      and position('aviator_cashout_token:sustained' in pg_get_functiondef(p.oid))>0
      and position('aviator_cashout_bet:burst' in pg_get_functiondef(p.oid))>0
      and position('aviator_cashout_bet:sustained' in pg_get_functiondef(p.oid))>0
  ) then
    raise exception 'cash-out Aviator sem rate limit por token/aposta';
  end if;

  if not exists(
    select 1
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='jl_aviator_reconnect'
      and position('jl_aviator_reconnect_rate_limit' in pg_get_functiondef(p.oid))>0
  ) then
    raise exception 'reconnect sem bridge de rate limit';
  end if;

  if not exists(
    select 1
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='jl_admin_account_id'
      and position('jl_rate_limit_enforce' in pg_get_functiondef(p.oid))>0
  ) then
    raise exception 'base administrativa sem rate limit';
  end if;

  if not exists(
    select 1
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='jl_require_admin_elevated'
      and position('jl_rate_limit_enforce' in pg_get_functiondef(p.oid))>0
  ) then
    raise exception 'ações administrativas elevadas sem rate limit';
  end if;

  perform public.jl_rate_limit_enforce(
    'point33-regression','subject',2,60,2,60
  );

  perform public.jl_rate_limit_enforce(
    'point33-regression','subject',2,60,2,60
  );

  begin
    perform public.jl_rate_limit_enforce(
      'point33-regression','subject',2,60,2,60
    );
  exception
    when others then
      if position('RATE_LIMITED:' in sqlerrm)>0 then
        v_blocked:=true;
      else
        raise;
      end if;
  end;

  if not v_blocked then
    raise exception 'terceira requisição não foi bloqueada';
  end if;
end
$test$;

rollback;

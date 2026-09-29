begin;

do $$
declare
  v_def text;
begin
  select pg_get_functiondef(
    'public.jl_aviator_cashout(text,bigint)'::regprocedure
  )
  into v_def;

  if position('pg_advisory_xact_lock_shared' in v_def)=0 then
    raise exception 'cash-out deve usar advisory lock compartilhado da rodada';
  end if;

  if position(
    'pg_advisory_xact_lock(hashtext(''jl_aviator_round_'''
    in v_def
  )>0 then
    raise exception 'cash-out nao deve manter lock exclusivo da rodada';
  end if;

  if position(
    'from public.jl_aviator_rounds' in lower(v_def)
  )=0 then
    raise exception 'cash-out deve continuar lendo a rodada';
  end if;

  if position(
    'v_cashout_at:=clock_timestamp()' in replace(v_def,' ','')
  )=0 then
    raise exception 'cash-out deve congelar o instante do servidor';
  end if;

  if position(
    'and balance>=v_profit' in replace(lower(v_def),' ','')
  )=0 then
    raise exception 'debito da banca deve validar reserva atomicamente';
  end if;
end
$$;

rollback;

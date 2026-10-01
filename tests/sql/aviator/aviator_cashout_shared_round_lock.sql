begin;

do $cashout_structure$
declare
  v_def text;
  v_public_def text;
  v_compact text;
  v_helper text;
  v_helper_compact text;
begin
  -- A lógica concorrente/financeira vive no core interno; o RPC público
  -- adiciona idempotência, rate-limit e tradução segura de erros.
  select pg_get_functiondef(
    'public.jl_aviator_cashout_core(text,bigint)'::regprocedure
  )
  into v_def;

  select pg_get_functiondef(
    'public.jl_aviator_cashout(text,bigint,text)'::regprocedure
  )
  into v_public_def;

  select pg_get_functiondef(
    'public.jl_aviator_cashout_locked(bigint,numeric,timestamptz,text)'::regprocedure
  )
  into v_helper;

  v_compact:=regexp_replace(lower(v_def),'[[:space:]]+','','g');
  v_helper_compact:=regexp_replace(lower(v_helper),'[[:space:]]+','','g');

  if position(
    'public.jl_aviator_cashout_core'
    in lower(v_public_def)
  )=0 then
    raise exception 'RPC público deve delegar ao core protegido do cash-out';
  end if;

  if position('pg_advisory_xact_lock_shared' in v_def)=0 then
    raise exception 'cash-out manual deve usar advisory lock compartilhado da rodada';
  end if;

  if position(
    'pg_advisory_xact_lock(hashtext(''jl_aviator_round_'''
    in v_def
  )>0 then
    raise exception 'cash-out manual nao deve manter lock exclusivo da rodada';
  end if;

  if position(
    'from public.jl_aviator_rounds' in lower(v_def)
  )=0 then
    raise exception 'cash-out manual deve continuar lendo a rodada';
  end if;

  if position(
    'v_cashout_at:=clock_timestamp()'
    in v_compact
  )=0 then
    raise exception 'cash-out manual deve congelar o instante do servidor';
  end if;

  if position(
    'public.jl_aviator_cashout_locked'
    in lower(v_def)
  )=0 then
    raise exception 'cash-out manual deve usar o liquidador financeiro compartilhado';
  end if;

  if position(
    'updatepublic.jl_aviator_banksetbalance=round(balance-v_profit,2)'
    in v_helper_compact
  )=0
  or position(
    'whereid=trueandbalance>=v_profit'
    in v_helper_compact
  )=0 then
    raise exception 'liquidador compartilhado deve validar reserva da banca atomicamente';
  end if;

  if position(
    'insertintopublic.transactions'
    in v_helper_compact
  )=0
  or position(
    'updatepublic.jl_aviator_betssetstatus=''cashed_out'''
    in v_helper_compact
  )=0
  or position(
    'updatepublic.playerssetbalance=round(balance+v_payout,2)'
    in v_helper_compact
  )=0 then
    raise exception 'liquidador compartilhado deve confirmar transacao, aposta e saldo juntos';
  end if;
end
$cashout_structure$;

rollback;

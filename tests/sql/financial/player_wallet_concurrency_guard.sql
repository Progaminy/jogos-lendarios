-- Ponto 30: serialização global dos débitos da carteira por jogador.
begin;

do $test$
declare
  missing_count integer;
begin
  if to_regprocedure('public.jl_lock_player_wallet(uuid)') is null then
    raise exception 'jl_lock_player_wallet(uuid) ausente';
  end if;

  if has_function_privilege('anon','public.jl_lock_player_wallet(uuid)','EXECUTE')
     or has_function_privilege('authenticated','public.jl_lock_player_wallet(uuid)','EXECUTE') then
    raise exception 'lock interno da carteira exposto ao cliente';
  end if;

  with required(name,args) as (
    values
      ('jl_aviator_place_bet','p_token text, p_amount numeric'),
      ('jl_aviator_place_bet','p_token text, p_amount numeric, p_request_key text, p_auto_cashout_multiplier numeric'),
      ('jl_place_bet','p_token text, p_selected_number integer, p_amount numeric'),
      ('jl_place_pair_bet','p_token text, p_number_a integer, p_number_b integer, p_amount numeric'),
      ('jl_ludo_commit_stake','p_token text, p_room uuid'),
      ('jl_ludo_reenter','p_token text, p_room uuid'),
      ('jl_request_withdrawal','p_token text, p_amount numeric'),
      ('jl_admin_adjust_balance','p_token text, p_player_id uuid, p_delta numeric, p_note text')
  )
  select count(*)
  into missing_count
  from required r
  left join pg_proc p
    on p.proname=r.name
   and pg_get_function_identity_arguments(p.oid)=r.args
  left join pg_namespace n
    on n.oid=p.pronamespace
   and n.nspname='public'
  where p.oid is null
     or n.oid is null
     or position('jl_lock_player_wallet' in lower(pg_get_functiondef(p.oid)))=0;

  if missing_count<>0 then
    raise exception '% fluxo(s) financeiro(s) sem wallet lock',missing_count;
  end if;

  if exists(
    select 1
    from public.players p
    where p.balance<0
       or round(p.balance,2)<>round(public.jl_player_ledger_balance(p.id),2)
  ) then
    raise exception 'saldo negativo ou divergente do ledger';
  end if;
end
$test$;

rollback;

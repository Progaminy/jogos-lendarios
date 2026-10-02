-- Point 64 regression: the global Aviator bank row must not be locked
-- before per-player cash-out work. This protects mass-cashout scalability
-- without weakening the atomic bank-reserve check.
begin;

do $bank_lock_order$
declare
  v_def text;
  v_compact text;
  v_player_pos integer;
  v_bank_pos integer;
  v_tx_pos integer;
begin
  select pg_get_functiondef(
    'public.jl_aviator_cashout_locked(bigint,numeric,timestamptz,text)'::regprocedure
  )
  into v_def;

  v_compact:=regexp_replace(lower(v_def),'[[:space:]]+','','g');

  v_tx_pos:=position('insertintopublic.transactions' in v_compact);
  v_player_pos:=position(
    'updatepublic.playerssetbalance=round(balance+v_payout,2)'
    in v_compact
  );
  v_bank_pos:=position(
    'updatepublic.jl_aviator_banksetbalance=round(balance-v_profit,2)'
    in v_compact
  );

  if v_tx_pos=0 or v_player_pos=0 or v_bank_pos=0 then
    raise exception 'Point 64: expected cash-out financial steps are missing';
  end if;

  if v_bank_pos<v_player_pos or v_bank_pos<v_tx_pos then
    raise exception
      'Point 64: shared bank row is locked too early and serializes cash-outs';
  end if;

  if position('whereid=trueandbalance>=v_profit' in v_compact)=0 then
    raise exception
      'Point 64: bank optimization removed the atomic reserve guard';
  end if;

  if position('raiseexception''reservadabancainconsistente.''' in v_compact)=0 then
    raise exception
      'Point 64: bank optimization removed rollback-on-insufficient-reserve';
  end if;
end
$bank_lock_order$;

rollback;

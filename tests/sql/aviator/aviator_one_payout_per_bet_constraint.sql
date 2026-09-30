-- Ponto 32: payout único por aposta garantido por constraint no banco.
begin;

do $test$
declare
  v_existing public.transactions%rowtype;
  v_duplicate_blocked boolean:=false;
begin
  if not exists(
    select 1
    from pg_constraint c
    where c.conrelid='public.transactions'::regclass
      and c.conname='transactions_one_aviator_payout_per_bet'
      and c.contype='u'
      and pg_get_constraintdef(c.oid)='UNIQUE (aviator_payout_bet_id)'
  ) then
    raise exception 'constraint UNIQUE de payout por aposta ausente';
  end if;

  if (
    select is_generated
    from information_schema.columns
    where table_schema='public'
      and table_name='transactions'
      and column_name='aviator_payout_bet_id'
  )<>'ALWAYS' then
    raise exception 'aviator_payout_bet_id não é generated always';
  end if;

  if exists(
    select aviator_payout_bet_id
    from public.transactions
    where aviator_payout_bet_id is not null
    group by aviator_payout_bet_id
    having count(*)>1
  ) then
    raise exception 'há payout duplicado por aposta';
  end if;

  if exists(
    select 1
    from public.transactions
    where aviator_operation='PAYOUT'
      and aviator_payout_bet_id is distinct from aviator_bet_id
  ) then
    raise exception 'chave canónica de payout diverge da aposta';
  end if;

  if exists(
    select 1
    from public.transactions
    where coalesce(aviator_operation,'')<>'PAYOUT'
      and aviator_payout_bet_id is not null
  ) then
    raise exception 'movimento não-PAYOUT recebeu chave de payout';
  end if;

  select *
  into v_existing
  from public.transactions
  where aviator_operation='PAYOUT'
  order by created_at
  limit 1;

  if v_existing.id is not null then
    begin
      insert into public.transactions(
        id,
        player_id,
        kind,
        amount,
        status,
        reference_id,
        note,
        aviator_bet_id,
        aviator_operation
      )
      values(
        gen_random_uuid(),
        v_existing.player_id,
        'aviator_payout',
        v_existing.amount,
        'completed',
        v_existing.reference_id,
        'Teste de payout duplicado',
        v_existing.aviator_bet_id,
        'PAYOUT'
      );
    exception
      when unique_violation then
        v_duplicate_blocked:=true;
    end;

    if not v_duplicate_blocked then
      raise exception 'banco aceitou segundo payout para a mesma aposta';
    end if;
  end if;

  if exists(
    select 1
    from public.jl_aviator_bets b
    left join public.transactions t on t.id=b.payout_transaction_id
    where b.status='CASHED_OUT'
      and (
        b.payout_transaction_id is null
        or t.id is null
        or t.aviator_bet_id<>b.id
        or t.aviator_payout_bet_id<>b.id
        or t.aviator_operation<>'PAYOUT'
        or t.kind<>'aviator_payout'
        or t.player_id<>b.player_id
        or t.amount<>b.payout
      )
  ) then
    raise exception 'ligação payout <-> aposta inconsistente';
  end if;
end
$test$;

rollback;

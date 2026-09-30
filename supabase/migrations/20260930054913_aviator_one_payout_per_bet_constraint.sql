
alter table public.transactions
  add column if not exists aviator_payout_bet_id bigint
  generated always as (
    case
      when aviator_operation='PAYOUT' then aviator_bet_id
      else null
    end
  ) stored;

do $$
begin
  if not exists(
    select 1
    from pg_constraint
    where conname='transactions_one_aviator_payout_per_bet'
      and conrelid='public.transactions'::regclass
  ) then
    alter table public.transactions
      add constraint transactions_one_aviator_payout_per_bet
      unique (aviator_payout_bet_id);
  end if;
end
$$;

comment on column public.transactions.aviator_payout_bet_id is
  'Generated only for Aviator PAYOUT rows. UNIQUE constraint guarantees at most one payout transaction per bet.';

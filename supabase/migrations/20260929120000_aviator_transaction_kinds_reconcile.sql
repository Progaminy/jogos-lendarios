-- Reconcilia o livro financeiro canónico com os tipos já usados pelo Aviator.
-- Produção já contém estes tipos; esta migration elimina a divergência entre
-- reconstrução local/CI e o banco ativo.

alter table public.transactions
  drop constraint if exists transactions_kind_check;

alter table public.transactions
  add constraint transactions_kind_check
  check (
    kind in (
      'deposit',
      'withdrawal',
      'withdrawal_refund',
      'bet',
      'payout',
      'adjustment',
      'ludo_stake',
      'ludo_reentry',
      'ludo_refund',
      'ludo_payout',
      'aviator_bet',
      'aviator_payout'
    )
  );

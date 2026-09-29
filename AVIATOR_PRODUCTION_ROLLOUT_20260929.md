# Aviator — implantação de produção (2026-09-29)

Este documento existe porque o histórico de migrations de produção possui versões antigas/equivalentes do Aviator com timestamps diferentes dos ficheiros canónicos do repositório.

## Condição antes da implantação

Manter o Aviator em manutenção. Confirmar antes de qualquer SQL:

```sql
select
  (select enabled from public.jl_aviator_settings where id=true) as enabled,
  (select count(*) from public.jl_aviator_rounds
    where status in ('OPEN','LOCKED','FLYING','CRASHED')) as live_rounds,
  (select count(*) from public.jl_aviator_bets where status='ACTIVE') as active_bets;
```

Esperado para implantação tranquila: `enabled=false`, `live_rounds=0`, `active_bets=0`.

## Não fazer

Não executar cegamente `supabase db push --include-all` enquanto o histórico de migrations antigo não estiver reconciliado. Produção já possui várias funções equivalentes a migrations `1100–1152` sob versões diferentes.

## Sequência final a aplicar/revisar

A partir do estado de produção observado em 2026-09-29, revisar/aplicar em ordem as definições finais:

1. `20260929115300_aviator_maintenance_complete.sql`
2. `20260929115400_aviator_maintenance_round_drain.sql`
3. `20260929115500_aviator_recent_results.sql`
4. `20260929115600_aviator_logical_crash_state.sql`
5. `20260929115700_aviator_player_state_bounded.sql`
6. `20260929115800_aviator_precommitted_visual_target.sql`
7. `20260929115900_aviator_multiplier_permissions.sql`
8. `20260929120000_aviator_transaction_kinds_reconcile.sql`
9. `20260929120100_aviator_reopen_after_cancel.sql`
10. `20260929120200_aviator_engine_self_heal.sql`

Aplicar pelo fluxo autorizado do Supabase. Não contornar bloqueios da integração.

## Validação depois do SQL

Manter `enabled=false` e conferir:

```sql
select status,count(*)
from public.jl_aviator_rounds
group by status
order by status;

select
  has_function_privilege('anon','public.jl_aviator_tick(bigint)','EXECUTE') as anon_tick,
  has_function_privilege('anon','public.jl_aviator_multiplier(timestamptz,timestamptz)','EXECUTE') as anon_multiplier,
  has_function_privilege('authenticated','public.jl_aviator_tick(bigint)','EXECUTE') as auth_tick;
```

Os três privilégios acima devem ser `false`.

Validar também a prova das rodadas concluídas:

```sql
select count(*) as proof_mismatches
from public.jl_aviator_rounds
where status in ('CRASHED','SETTLED')
  and visual_seed_commit is not null
  and visual_seed_reveal is not null
  and visual_seed_commit <> encode(extensions.digest(visual_seed_reveal,'sha256'),'hex');
```

Esperado: `0`.

## Antes de abrir ao público

- CI do `main` verde.
- Nenhuma aposta ativa antiga.
- Nenhuma rodada `LOCKED`, `FLYING` ou `CRASHED` presa.
- Banca verificada pelo admin; lembrar que banca muito baixa produz teto próximo de 1x.
- Fazer uma rodada controlada de valor baixo, testar refresh/reconexão/cash-out e confirmar ledger/audit.
- Só depois usar **Abrir Aviator** no admin.

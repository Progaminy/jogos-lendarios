# Snapshot de produção — 2026-09-28

Este ficheiro foi criado no âmbito do ponto 25 da auditoria para registrar o estado canónico do Supabase em produção sem alterar lógica de jogo.

## Estado reconciliado

- Migrations em produção: **102**
- Migrations em `main/supabase/migrations`: **102**
- Diferenças de versão/nome/conteúdo após reconciliação: **0**
- Última migration canónica: `20260928014639_reconcile_live_ludo_roll_definition_20260928`
- Tabelas públicas: **40**
- Funções públicas: **194**
- Triggers públicos: **24**
- Índices públicos: **125**

## Fingerprints do estado real

```text
columns_sha256   = dad24164ed57082cdc36b98e2ba38f0771557b5bfb69d9b4863a2c432aee1337
functions_sha256 = 0ca7705f4f30d777634d2241621dcc51bd33278b067d343de262a3338fd8b993
triggers_sha256  = f5da7031771e165a1fff03bf7efcf2a527b09ec072b6d79cf37100a46a6b8cbe
indexes_sha256   = 499320165d8c8db7b5689c420d31b7616ac1f9b69afc00bd482be1d88e287e4c
jl_ludo_roll     = acac1f3a1fff93c7c0f088f292609cf40ec55b89b15fcb8fd7e34505125c1373
```

## Drift conhecido reconciliado

A definição de `public.jl_ludo_roll(text, uuid)` continha alterações feitas diretamente em produção que não estavam representadas no histórico de migrations.

No ponto 25 **nenhuma lógica foi corrigida ou alterada**. A definição instalada foi apenas capturada exatamente como estava e registrada pela migration:

```text
20260928014639_reconcile_live_ludo_roll_definition_20260928
```

A assinatura SHA-256 da função antes e depois dessa migration permaneceu idêntica.

## Regra canónica a partir deste snapshot

1. `supabase/migrations` é o histórico canónico do banco.
2. Nenhuma função, trigger, tabela, índice, grant, policy ou cron deve ser alterado diretamente em produção sem migration equivalente.
3. Se uma correção de emergência precisar ocorrer diretamente em produção, a definição exata aplicada deve ser transformada imediatamente em migration e enviada ao `main` antes de qualquer nova alteração de banco.
4. Nunca renomear retrospectivamente timestamps de migrations já aplicadas. O nome do ficheiro no GitHub deve corresponder à versão e ao nome registrados no Supabase.
5. Antes de uma mudança de banco, comparar o histórico de produção com `supabase/migrations`. Qualquer divergência deve ser resolvida antes de continuar.
6. Alterações de lógica pertencem ao ponto funcional correspondente; este mecanismo de reconciliação não deve “corrigir” comportamento silenciosamente.


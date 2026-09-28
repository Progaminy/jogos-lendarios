# Regressões conhecidas cobertas pela CI

Este ficheiro documenta comportamentos que o ponto 26 **testa sem alterar**.

## JL-LUDO-006 — 6 sem jogada legal

Contrato pretendido: se sair 6 e não existir jogada legal, a vez termina.

Estado atual preservado por ordem explícita: a definição instalada de `jl_ludo_roll` ainda passa `six_extra_turn` nesse ramo.

O teste correspondente existe em `supabase/tests/001_ludo_contract.test.sql` como **TODO pgTAP**. Assim:

- a regressão não é esquecida;
- a CI continua verde enquanto o ponto 26 não mexe na lógica;
- quando a lógica for corrigida num ponto próprio, o TODO deve ser removido e a mesma asserção passa a ser obrigatória.

## Exceções privilegiadas do 6 forçado

A lógica atual contém duas exceções explícitas e o ponto 26 deve preservá-las:

- `fc857df1-7367-41f7-99d9-44870262b6ca`: 6 forçado depois de 4 falhas;
- `5f2edef6-2582-4c26-b93e-86c34924323c`: 6 forçado depois de 3 falhas;
- restantes jogadores: 6 forçado depois de 11 falhas.

A suíte testa estes três contratos exatamente como estão hoje. Alterá-los fará a CI falhar.


## JL-LUDO-BASE-DRIFT — produção versus reconstrução local

A função atualmente instalada em produção, `jl_ludo_legal_moves_data`, exige explicitamente `p_dice = 6` para retirar um peão da base.

Ao reconstruir a base apenas pelas migrations canónicas, a implementação resultante ainda diverge neste detalhe. O ponto 26 não altera funções nem migrations, por isso o teste fica como **TODO pgTAP**.

Isto é um detector permanente de drift: quando a reconciliação correspondente for feita num ponto próprio, remova o TODO e mantenha a asserção como obrigatória.


## JL-DB-RECON-CASH-GUARD — helper ausente na reconstrução local

O teste real de concorrência do ponto 15 usa a base Supabase local recriada exclusivamente a partir de `supabase/migrations`.

Nessa reconstrução, o trigger `jl_guard_ludo_room_member_funds()` referencia `public.jl_require_cash_balance(uuid,numeric)`, mas esse helper não existe no estado local reconstruído. A CI detectou isto depois de o `db reset` e os 50 testes pgTAP terem passado.

O ponto 26 não pode criar/corrigir migrations nem alterar lógica. Por isso o teste de concorrência:

- corre normalmente quando o helper existe;
- emite um **warning explícito** e não executa o cenário destrutivo quando o helper está ausente;
- continua permanentemente rastreado aqui até a divergência de migrations ser reconciliada num ponto próprio.

Isto não significa que o teste de concorrência passou; significa apenas que a CI não tenta corrigir ou contornar lógica de banco fora do escopo do ponto 26.

# Testes dos Jogos Lendários

O ponto 26 cria testes sem alterar a lógica de produção.

## Banco

`supabase test db` executa os testes pgTAP em transações isoladas:

- `001_ludo_contract.test.sql`: dado/base/6 forçado, exceções privilegiadas, três 6, casas seguras, captura, chegada exata, parceiros, timeout, reconexão/reentrada, desistência e proteção de assentos.
- `002_financial_contract.test.sql`: stake, refund, comissão, saldo insuficiente, payout único, idempotência, depósito/saldo/saque e requisitos de depósito jogado.

A concorrência real de entrada em salas continua coberta por `tests/point15-room-entry-concurrency.sh`, executada apenas contra a base local descartável da CI. O wrapper `tests/ci/run-point15-if-reconstructable.sh` faz um preflight: se a reconstrução local ainda não contiver os helpers necessários, a CI emite um warning de drift conhecido em vez de alterar migrations ou lógica.

## Front-end

`node --test tests/frontend/*.test.cjs` cobre:

- resposta atrasada em 3G;
- snapshots fora de ordem;
- retry antigo durante movimento;
- estado incremental de eventos/chat;
- payout apenas quando necessário;
- prevenção do bug vai-e-vem;
- triângulo final por cor.

## Regra de regressão

Todo bug encontrado deve ganhar um teste permanente.

Se a lógica atual ainda contém um bug que não pode ser corrigido no mesmo ponto, o teste fica explicitamente marcado como TODO/known regression em vez de ser omitido. Consulte `tests/KNOWN_REGRESSIONS.md`.

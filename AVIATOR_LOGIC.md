# Aviator Lendário — lógica financeira congelada

Fase 1 do motor.

- Todas as apostas válidas são aceites; o teto não é usado para rejeitar uma aposta.
- A banca do Aviator é separada do dinheiro apostado pelos jogadores.
- A reserva financeira de cada rodada é 50% do saldo da banca no instante do fecho.
- Teto financeiro: `1 + (reserva / total_apostado)`.
- Ex.: banca 200.000 MZN, reserva 100.000 MZN e apostas 100.000 MZN => teto 2x.
- Ex.: banca 100.000 MZN, reserva 50.000 MZN e apostas 100.000 MZN => teto 1,5x.
- O snapshot, a reserva e o teto ficam congelados em `LOCKED`; cash-outs posteriores não recalculam o teto.
- A extensão visual depois de todos os jogadores terem saído será implementada na fase seguinte. O intervalo discutido é 5x–135,7x, mas não é ainda regra executável nesta migration.
- RPCs de fecho/motor permanecem apenas para `service_role`; o cliente não decide teto, crash ou liquidação.

## Fase 2 — voo e cash-out

- O alvo visual é sorteado **antes do voo**, entre 5x e 135,7x, e fica comprometido por hash.
- Com apostas activas, o alvo efectivo continua a ser o teto financeiro congelado.
- O multiplicador é função do tempo do servidor; não exige escrita na base a cada frame.
- Cash-out usa o relógio do servidor e é transaccional/idempotente por estado da aposta.
- Quando a última aposta activa sai antes do teto financeiro, a responsabilidade financeira termina e o alvo efectivo passa para o alvo visual já pré-calculado (nunca abaixo do multiplicador já alcançado).
- No crash, apostas ainda activas perdem; os stakes perdidos entram na banca uma única vez.
- O lucro pago num cash-out é debitado da banca; a devolução do stake não é tratada como dinheiro da banca.

# Aviator Lendário — lógica financeira congelada

Fase 1 do motor.

- Todas as apostas válidas são aceites; o teto não é usado para rejeitar uma aposta.
- A banca do Aviator é separada do dinheiro apostado pelos jogadores.
- A reserva financeira de cada rodada é 50% do saldo da banca no instante do fecho.
- Teto financeiro: `1 + (reserva / total_apostado)`.
- Ex.: banca 200.000 MZN, reserva 100.000 MZN e apostas 100.000 MZN => teto 2x.
- Ex.: banca 100.000 MZN, reserva 50.000 MZN e apostas 100.000 MZN => teto 1,5x.
- O snapshot, a reserva e o teto ficam congelados em `LOCKED`; cash-outs posteriores não recalculam o teto.
- RPCs de fecho/motor permanecem apenas para `service_role`; o cliente não decide teto, crash ou liquidação.

## Fase 2 — voo e cash-out

- O alvo visual é sorteado **antes do voo**, entre 5x e 135,7x, e fica comprometido por hash.
- Com apostas activas, o alvo efectivo continua a ser o teto financeiro congelado.
- O multiplicador é função do tempo do servidor; não exige escrita na base a cada frame.
- Cash-out usa o relógio do servidor e é transaccional/idempotente por estado da aposta.
- Quando a última aposta activa sai antes do teto financeiro, a responsabilidade financeira termina e o alvo efectivo passa para o alvo visual já pré-calculado (nunca abaixo do multiplicador já alcançado).
- No crash, apostas ainda activas perdem; os stakes perdidos entram na banca uma única vez.
- O lucro pago num cash-out é debitado da banca; a devolução do stake não é tratada como dinheiro da banca.

## Estado lógico do crash

- A liquidação financeira pode continuar a ser executada pelo cron global de 2 segundos.
- O estado público não precisa esperar a próxima execução do cron para parar visualmente o voo.
- Enquanto a linha ainda está `FLYING`, o servidor compara o relógio atual com o alvo internamente e pode devolver `CRASHED` de forma lógica, sem escrever na rodada.
- O cliente recebe o multiplicador final somente quando o alvo já foi atingido.
- `financial_ceiling`, `effective_target`, `visual_target` e totais internos não são expostos no estado público antes do crash.
- O cash-out continua usando o relógio e as travas do servidor; a indicação visual do navegador nunca autoriza pagamento.

## Resiliência e concorrência

- A colocação de aposta usa `request_key` persistida no `sessionStorage` por rodada. Retry da mesma ação reutiliza a mesma chave.
- `jl_aviator_player_state` recupera a aposta ativa depois de refresh, reconexão ou retorno da aplicação.
- Cash-out e crash são serializados por rodada; a decisão final pertence ao servidor.
- A seed do alvo visual fica em `jl_aviator_round_secrets`, sem acesso de navegador, e só é publicada após crash/liquidação.
- Ao chegar a zero apostas ativas, termina a responsabilidade financeira e o alvo passa para a extensão visual comprometida.
- O executor respeita a pausa pós-liquidação antes de abrir a rodada seguinte.

## Manutenção

- `enabled=false` bloqueia novas apostas e impede a abertura de novas rodadas.
- Uma rodada `OPEN` sem apostas é cancelada ao entrar em manutenção.
- Uma rodada `OPEN` que já tenha aposta aceite não é apagada: fecha normalmente e segue para voo/liquidação.
- Uma rodada `FLYING` nunca é interrompida por manutenção; jogadores com aposta ativa mantêm o cash-out até a liquidação.
- Para quem não possui aposta protegida em voo, a interface fechada mostra apenas **“Aviator brevemente”**.
- O toggle administrativo, a entrada de aposta e o motor usam trava de manutenção para evitar corrida entre fechar o jogo e aceitar nova aposta.

## Estado de implantação

As migrations e o código do motor ficam versionados no repositório. Uma migration só deve ser considerada ativa em produção depois de constar no histórico do Supabase de produção.

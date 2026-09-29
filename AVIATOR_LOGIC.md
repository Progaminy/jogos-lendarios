# Aviator Lendário — lógica financeira congelada

## Núcleo financeiro

- A aposta mínima é **0,50 MZN**; valores monetários são tratados com 2 casas decimais.
- Todas as apostas válidas são aceites; o teto não é usado para rejeitar uma aposta.
- A banca do Aviator é separada do dinheiro apostado pelos jogadores.
- A reserva financeira da rodada é 50% do saldo da banca no instante do fecho.
- Teto financeiro: `1 + (reserva / total_apostado)`.
- Ex.: banca 200.000 MZN, reserva 100.000 MZN e apostas 100.000 MZN => teto 2x.
- Ex.: banca 100.000 MZN, reserva 50.000 MZN e apostas 100.000 MZN => teto 1,5x.
- O snapshot, a reserva e o teto ficam congelados em `LOCKED`; cash-outs posteriores não recalculam o teto.
- RPCs de motor/crash permanecem apenas para `service_role`; o navegador não decide teto, crash ou liquidação.

## Voo, alvo visual e cash-out

- O alvo visual é sorteado **antes do voo**, entre 5x e 135,7x, em todas as rodadas, e fica comprometido por hash.
- Com apostas ativas, o alvo efetivo continua a ser o teto financeiro congelado; o alvo visual pré-comprometido não governa a exposição.
- O multiplicador é função do tempo do servidor; não exige escrita na base a cada frame.
- O estado público devolve `current_multiplier` e `seconds_to_close` calculados no servidor; o navegador não possui fórmula de voo nem relógio autoritativo e limita-se a desenhar snapshots recebidos.
- Cash-out usa o relógio do servidor e é transacional/idempotente por estado da aposta.
- Quando a última aposta ativa sai antes do teto financeiro, a responsabilidade financeira termina e o alvo efetivo passa para `greatest(alvo_visual_precomprometido, multiplicador_ja_alcancado)`.
- O último cash-out **não sorteia outro alvo**.
- No crash, apostas ainda ativas perdem; stakes perdidos entram na banca uma única vez.
- O lucro pago num cash-out é debitado da banca; a devolução do stake não é tratada como dinheiro da banca.

## Provably fair e prova da rodada

- Versão atual da prova: `JL-AVIATOR-PF-v2`.
- Uma seed aleatória de 256 bits é criada quando a rodada `OPEN` nasce, antes das apostas, e permanece apenas na tabela privada de segredos.
- O navegador recebe apenas `SHA-256(seed)` durante `OPEN`; a seed não é revelada antes do crash.
- O alvo visual é derivado deterministicamente dos primeiros 52 bits do hash comprometido, permitindo reprodução idêntica no navegador.
- Em `LOCKED`, um segundo SHA-256 sela: versão, rodada, commit da seed, total apostado, teto financeiro, alvo visual e alvo efetivo congelado.
- A seed da rodada é imutável; tentativa de substituí-la é rejeitada por trigger.
- Depois do crash, `jl_aviator_round_proof(round_id)` publica seed, payload do lock, compromissos e resultado para verificação.
- O navegador recalcula SHA-256 da seed e do payload e compara o multiplicador final sem confiar apenas no campo `proof_valid` devolvido pelo servidor.
- Qualquer alteração posterior no resultado ou nos inputs congelados quebra a prova.
- Importante: com apostas ativas, a regra económica existente continua a governar o alvo efetivo pelo teto financeiro congelado. Portanto a v2 prova que o resultado não foi alterado depois do compromisso, mas não transforma essas rodadas em um crash puramente aleatório governado apenas pela seed.

## Estado lógico do crash

- A escrituração/liquidação continua no cron global de 2 segundos.
- O estado público pode devolver `CRASHED` logicamente assim que o relógio do servidor alcança o alvo, sem esperar a próxima escrita do cron.
- O estado público de alta frequência não faz `count(*)` das apostas e lê apenas as colunas necessárias da rodada.
- O cliente recebe o multiplicador final somente quando o alvo já foi atingido.
- `financial_ceiling`, `effective_target`, `visual_target` e totais internos não são expostos no estado público antes do crash.
- O cash-out continua usando o relógio e as travas do servidor; a indicação visual nunca autoriza pagamento.

## Resiliência, reconexão e concorrência

- A colocação de aposta usa `request_key` persistida no `sessionStorage` por rodada.
- Existe no máximo uma aposta por jogador/rodada, garantida por índice único no banco.
- Apostas de jogadores diferentes usam lock compartilhado de manutenção e `FOR SHARE` na rodada, evitando serialização global sem abrir corrida com manutenção/fecho.
- `jl_aviator_player_state` recupera a aposta ativa após refresh, reconexão ou retorno à aplicação.
- Respostas de recuperação antigas são descartadas quando a rodada mudou.
- Cash-out e crash são serializados pela mesma rodada.
- Um cash-out com resposta de rede ambígua grava apenas `bet_id/round_id` temporariamente no `sessionStorage`; na reconexão o cliente consulta o estado do servidor e **não repete automaticamente** a operação.
- Se o servidor já marcou `CASHED_OUT`, o cliente mostra multiplicador e payout confirmados; se continua `ACTIVE`, restaura o botão; se ficou `LOST`, encerra a rodada.
- A seed fica em `jl_aviator_round_secrets`, sem acesso de navegador, e só é publicada depois do crash/liquidação.
- O executor respeita a pausa pós-liquidação antes de abrir a rodada seguinte.

## Auto-heal do ciclo

O cron chama `jl_process_game_engine_tick()`. O caminho real possui recuperação para estados transitórios persistidos:

- `CANCELLED` + Aviator reaberto => cria nova `OPEN`.
- `LOCKED` persistente => `FLYING`, preservando snapshot, teto e alvo já congelados.
- `CRASHED` persistente => publica a prova e conclui como `SETTLED`.
- `FLYING` continua sendo processado normalmente até crash/liquidação.
- Um índice único parcial impede duas rodadas transitórias coexistirem, incluindo `CRASHED`.
- Um índice parcial por `id desc` mantém a busca da rodada transitória barata mesmo com histórico grande.

Esses cenários têm regressões transacionais em `tests/sql/aviator/`.

## Manutenção

- `enabled=false` bloqueia novas apostas e impede novas rodadas.
- Uma `OPEN` sem apostas é cancelada ao entrar em manutenção.
- Uma `OPEN` com aposta aceite não é apagada: fecha e segue para voo/liquidação.
- Uma `FLYING` nunca é interrompida por manutenção; jogador com aposta ativa mantém cash-out.
- Para quem não possui aposta protegida em voo, a interface mostra apenas **“Aviator brevemente”**.
- Toggle administrativo, aposta e motor usam trava de manutenção para evitar corrida.

## Teste operacional de uma rodada

- O admin pode armar exatamente **1 rodada real de teste**.
- O modo só pode ser iniciado sem rodada transitória existente.
- A rodada usa o mesmo motor, apostas, cash-out, teto, prova e ledger da operação normal.
- Após `SETTLED`, o backend define `enabled=false` e limpa o flag one-shot antes do próximo cron.
- Toggle manual de manutenção cancela o flag de teste.
- O botão do admin não inicia automaticamente nesta implantação; exige clique e confirmação do administrador.

## Ledger operacional da banca

- Ajustes administrativos continuam com `request_key` fornecida pelo admin.
- Lucro pago em cash-out gera `cashout:<bet_id>` com delta negativo.
- Stakes perdidos creditados no crash geram `lost-round:<round_id>` com delta positivo.
- O movimento do ledger é gravado na mesma transação do saldo da banca; falha posterior desfaz ambos.
- Movimentos operacionais de valor zero não criam linha.
- O índice único de `request_key` protege contra duplicação lógica.
- O admin consulta os movimentos por RPC separada, limitada a 50 linhas; a interface carrega 30 por vez somente ao expandir o histórico.

## Operação da banca

- Ajustes negativos da banca são bloqueados durante `LOCKED` ou `FLYING`.
- O admin mostra aviso informativo quando a banca atual implicaria teto muito baixo para uma referência de 10 MZN.
- O aviso não altera saldo e não muda a fórmula.
- Banca baixa pode produzir crash financeiro muito próximo de 1x; isso é consequência da fórmula, não erro visual.

## Estado de implantação

Em 2026-09-29, o bloco final de manutenção, histórico leve, crash lógico, estado privado limitado, alvo visual pré-comprometido, permissões, reconciliação financeira, reabertura e auto-heal foi aplicado e verificado em produção com o Aviator fechado. Novas migrations posteriores continuam exigindo aplicação e verificação explícitas.

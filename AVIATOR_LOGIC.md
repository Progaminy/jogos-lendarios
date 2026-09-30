# Aviator Lendário — lógica financeira congelada

## Núcleo financeiro

- A aposta por jogador fica entre **0,50 MZN e 500 MZN por rodada**. Não existe teto máximo total da rodada; vários jogadores podem apostar 500 MZN cada. A RPC valida os dois limites e a tabela `jl_aviator_bets` reforça com `CHECK (stake >= 0.50 AND stake <= 500.00)`.
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

## Mensagens limpas para o jogador

- Nenhuma exceção bruta do backend é mostrada diretamente na interface.
- Erros conhecidos são traduzidos para mensagens curtas e compreensíveis, como saldo insuficiente, apostas fechadas, fim da rodada ou falta de ligação.
- Erros desconhecidos usam mensagens genéricas seguras; nomes de RPC, SQL, stack trace e detalhes internos não são exibidos.
- Quebras reais e literais `\\n` são normalizadas antes de qualquer mensagem chegar ao jogador.
- A verificação provably fair continua funcionando, mas a interface mostra apenas estados simples: rodada protegida, rodada verificada ou verificação indisponível.
- Hashes, seeds e payloads técnicos permanecem fora da interface normal do jogador.

## Separação entre animação e resultado financeiro

- O avião, a grelha, o rastro e a animação CSS são estritamente visuais. A área de voo está marcada como `data-visual-only="true"` e os elementos animados não recebem eventos de ponteiro.
- O navegador não calcula crash, payout nem multiplicador financeiro a partir de `started_at`, relógio local, `requestAnimationFrame` ou fórmula própria.
- O multiplicador mostrado vem de `round.current_multiplier`, produzido pelo servidor no snapshot canónico.
- O cash-out manual envia somente `token + bet_id`; não existe parâmetro de multiplicador ou payout vindo do cliente.
- O servidor calcula o instante/multiplicador de cash-out, grava `cashout_multiplier`, `payout`, transação, saldo e banca na mesma transação.
- O crash é decidido pelo motor do servidor, persistido em `jl_aviator_rounds.crash_multiplier` e só depois refletido pela interface.
- Desativar CSS, reduzir animação, trocar o emoji do avião ou manipular o DOM não altera resultado financeiro.

## Reconexão autoritativa

- Ao recuperar a ligação, o cliente chama `jl_aviator_reconnect(token)`, que devolve no mesmo snapshot o estado público da rodada e o estado financeiro do jogador.
- O RPC usa lock compartilhado do engine enquanto lê o snapshot, impedindo que o motor mude de fase no meio da reconexão.
- O cliente aceita apenas snapshots com `display_seq` canónico do servidor; snapshots mais antigos continuam descartados.
- Se a rodada ainda estiver `FLYING`, o jogador retoma no multiplicador atual calculado pelo servidor. Não existe reinício em 1,00x nem reconstrução local do tempo perdido.
- Se um auto cash-out ocorreu enquanto o jogador estava offline, a reconexão retorna a aposta `CASHED_OUT`, a origem `AUTO`, o multiplicador e o payout reais.
- Se o crash ocorreu enquanto o jogador estava offline, a reconexão retorna `CRASHED/SETTLED` e a aposta já liquidada como `LOST` ou `CASHED_OUT`; o cliente não mantém um voo antigo.
- A classe visual da fase não é removida/reaplicada quando a fase não mudou, evitando reinício artificial da animação do avião em cada polling/reconexão.
- O mesmo fluxo de ressincronização é usado ao voltar de offline e ao regressar à aba depois de ela ficar oculta.

## Imutabilidade da aposta confirmada

- Depois que o servidor confirma uma aposta, os termos principais ficam imutáveis no banco: `round_id`, `player_id`, `stake`, `request_key`, `auto_cashout_multiplier` e `created_at`.
- A proteção é mais forte que o mínimo exigido pelo estado LOCKED: mesmo durante BETTING uma aposta já confirmada não pode ter o valor ou o auto cash-out reescritos. Para mudar a intenção, seria necessário um fluxo explícito de cancelamento/reaposta, que não existe hoje.
- Quando a rodada entra em **LOCKED**, qualquer tentativa de alterar esses termos continua bloqueada inclusive por UPDATE direto ou caminho privilegiado.
- O trigger não impede o motor de atualizar campos de liquidação, como `status`, `payout`, `cashout_multiplier`, `cashout_source` e `payout_transaction_id`.
- Na interface, os campos de valor e auto cash-out ficam desativados assim que a aposta é confirmada e permanecem bloqueados em LOCKED/FLYING.

## Cash-out automático opcional

- O jogador pode deixar o campo vazio ou indicar um alvo como **1,50x**, **2,00x** ou outro valor com até 2 casas decimais.
- A preferência é gravada na aposta como `auto_cashout_multiplier` antes do bloqueio da rodada.
- O navegador **não executa** o auto cash-out. O motor do servidor verifica os alvos em cada tick e liquida a aposta mesmo com o jogador offline.
- O pagamento usa exatamente o alvo definido pelo jogador. Se o motor observar 1,57x e o alvo era 1,50x, o payout é calculado em **1,50x**.
- A ordem matemática dos eventos prevalece sobre a frequência do tick: se auto=1,50x e crash=1,60x, o auto cash-out é pago mesmo que um tick chegue depois de 1,60x.
- Se o auto cash-out for **igual ou superior ao crash**, ele não é pago; o crash vence na igualdade.
- O auto cash-out reutiliza a mesma transação financeira atómica do cash-out manual, com uma única transação, débito da banca, auditoria e proteção idempotente.
- `cashout_source` registra `AUTO` ou `MANUAL`; retries de uma aposta já paga apenas devolvem o resultado existente.
- O processador interno de auto cash-out não é executável por `anon` nem `authenticated`.

## Cash-out atómico e idempotente

- Cada cash-out usa um lock específico da aposta antes do lock compartilhado da rodada.
- Duas requisições simultâneas da mesma aposta não podem pagar duas vezes: a primeira processa; a segunda relê o estado e devolve o mesmo resultado com `already_processed=true`.
- O instante financeiro do cash-out é congelado com `clock_timestamp()` no servidor antes de qualquer espera posterior pela banca.
- A banca, a transação de payout, a aposta e o saldo do jogador fazem parte da mesma transação PostgreSQL; qualquer falha provoca rollback completo.
- `payout_transaction_id` possui FK para `transactions(id)` e índice único.
- Uma aposta `CASHED_OUT` só é válida com multiplicador, payout, horário e transaction id preenchidos.
- Depois de paga, a parte financeira da aposta fica imutável por trigger.
- Retry após timeout/resposta perdida retorna o mesmo `transaction_id`, multiplicador e payout; não cria novo crédito, ledger ou auditoria.

## Idempotência financeira fim a fim

- Cada movimento de dinheiro do Aviator no ledger `transactions` possui agora uma identidade canónica formada por `aviator_bet_id + aviator_operation`.
- Para cada aposta podem existir no máximo três operações distintas: `BET` (débito da aposta), `PAYOUT` (pagamento de cash-out) e `REFUND` (reembolso). Um índice único impede duas linhas da mesma operação para a mesma aposta.
- A colocação de aposta continua usando `request_key` idempotente; um retry devolve a mesma aposta e o mesmo `transaction_id` do débito já confirmado, sem novo desconto de saldo.
- Cash-out manual e automático convergem no mesmo caminho financeiro interno. Depois de pago, qualquer retry devolve o mesmo `payout_transaction_id`, multiplicador e payout.
- Reembolso por manutenção e cancelamento administrativo convergem na mesma operação `REFUND`; uma aposta já reembolsada não pode receber um segundo reembolso.
- `payout_transaction_id` e `refund_transaction_id` continuam ligados por FK à tabela `transactions`, com índices únicos específicos, enquanto o ledger acrescenta a proteção independente por operação.
- Saldo do jogador, estado da aposta, transação, banca, ledger da banca e auditoria são confirmados dentro da mesma transação PostgreSQL; qualquer exceção provoca rollback completo.
- O histórico financeiro Aviator existente foi reconciliado com as novas identidades canónicas antes da constraint ser ativada, evitando linhas antigas sem vínculo.
- A proteção é deliberadamente em camadas: locks e estados impedem concorrência lógica; constraints e índices únicos impedem duplicação financeira mesmo se um caminho interno tentar repetir a operação.
- A migration de produção é `20260930000422_aviator_financial_operation_idempotency`, com regressão permanente em `tests/sql/aviator/aviator_financial_operation_idempotency.sql`.

## Ciclo da rodada e janela de bloqueio

- O ciclo público é **BETTING → LOCKED → FLYING → CRASHED → SETTLED**.
- Internamente, o status legado `OPEN` continua representando `BETTING` para compatibilidade com RPCs e migrations antigas; o estado público expõe `phase: BETTING`.
- Cada nova rodada abre com 12 segundos até a descolagem.
- As apostas fecham **3 segundos antes da descolagem**: 9 segundos em BETTING e 3 segundos em LOCKED.
- `betting_closes_at` e `takeoff_at` são definidos pelo servidor. O relógio do navegador nunca decide se uma aposta entrou.
- Durante LOCKED, nenhuma nova aposta é aceita e o saldo não é debitado por tentativas tardias.
- O motor não pode iniciar FLYING antes de `takeoff_at`.
- CRASHED fica realmente gravado/observável por um ciclo do motor; apenas o tick seguinte move a rodada para SETTLED.
- A interface mostra “APOSTAS FECHADAS” e contagem para a descolagem durante LOCKED.

## Fonte única do multiplicador visível

- O multiplicador público usa frames canónicos de **250 ms** do relógio do servidor.
- Cada resposta traz `display_seq`, `display_at` e `display_frame_ms`.
- O mesmo `display_seq` produz exatamente o mesmo `current_multiplier` para todos os jogadores.
- O crash financeiro/lógico continua a usar o instante exato do servidor; a quantização existe apenas para o número apresentado.
- O navegador nunca recalcula o multiplicador e nunca aceita um snapshot com `display_seq` menor do que o último já apresentado.
- Uma reconexão cancela a requisição de estado anterior antes de pedir o snapshot atual, impedindo resposta antiga de sobrescrever estado novo.
- Polling continua moderado; consistência não depende de aumentar agressivamente a frequência de chamadas.
- Latência de rede ainda pode fazer um jogador receber um frame novo alguns milissegundos antes de outro, mas dois clientes nunca têm valores contraditórios para o mesmo frame autoritativo.

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

- O painel possui uma ação dedicada **Fechar Aviator**, implementada por `jl_aviator_admin_close(token)`; ela só fecha e nunca reabre o jogo.
- Existe uma ação separada **Reabrir Aviator**, implementada por `jl_aviator_admin_reopen(token)`; ela nunca fecha o jogo e exige confirmação explícita.
- O fecho e o motor usam a mesma ordem de locks `engine -> maintenance`, evitando corrida/deadlock entre aposta, motor e manutenção.
- Assim que o fecho é confirmado, `enabled=false` bloqueia novas apostas e novas rodadas.
- Se a rodada ainda estiver `OPEN` ou `LOCKED`, ela é cancelada antes da descolagem e todas as apostas `ACTIVE` são reembolsadas atomicamente.
- Cada reembolso restaura o saldo do jogador, marca a aposta como `REFUNDED`, grava `refunded_at`, liga `refund_transaction_id` e cria uma transação `aviator_refund`.
- Repetir o fecho é idempotente: um reembolso já concluído não é pago novamente.
- Se a rodada já estiver `FLYING`, ela não é cancelada nem reembolsada arbitrariamente; continua pelo motor normal até `CRASHED` e depois `SETTLED`.
- Se já estiver `CRASHED`, o motor conclui a liquidação; não fica rodada financeira presa.
- O cron considera qualquer rodada transitória durante manutenção como trabalho pendente, garantindo drenagem mesmo após reinício/reentrada do worker.
- O painel informa quantas apostas e quanto valor foram reembolsados quando o fecho ocorre antes do voo.
- A reabertura é bloqueada enquanto ainda houver `OPEN`, `LOCKED`, `FLYING` ou `CRASHED` pendente.
- Para quem não possui aposta protegida em voo, a interface mostra apenas **“Aviator brevemente.”**.

## Teste operacional de uma rodada

- O admin pode armar exatamente **1 rodada real de teste**.
- O modo só pode ser iniciado sem rodada transitória existente.
- A rodada usa o mesmo motor, apostas, cash-out, teto, prova e ledger da operação normal.
- Após `SETTLED`, o backend define `enabled=false` e limpa o flag one-shot antes do próximo cron.
- Toggle manual de manutenção cancela o flag de teste.
- O botão do admin não inicia automaticamente nesta implantação; exige clique e confirmação do administrador.

## Ledger financeiro do jogador

- O saldo do jogador e o histórico financeiro foram separados. `players.balance` permanece apenas como cache operacional compatível com o restante da plataforma; a fonte contabilística passa a ser `player_financial_ledger`.
- Cada linha de `transactions` gera exatamente um lançamento append-only no ledger, com `transaction_id`, `player_id`, `delta`, `balance_after`, tipo, referência, estado no momento do lançamento e timestamps.
- O histórico existente foi migrado integralmente e reconciliado: todos os movimentos reconstruíram exatamente os saldos atuais, sem saldo inicial artificial.
- Saque rejeitado preserva o débito original e cria um `withdrawal_refund` separado. O estado do pedido pode mudar, mas o movimento contabilístico original não é reescrito.
- Campos financeiros de `transactions` são imutáveis depois do lançamento: jogador, tipo, valor, referência, timestamp e vínculos do Aviator não podem ser alterados. Apenas campos de workflow, como `status` e `note`, podem evoluir quando necessário.
- O ledger bloqueia `UPDATE` e `DELETE` por trigger. A FK `transaction_id -> transactions(id)` também impede apagar a transaction de origem.
- Dois constraint triggers diferidos verificam a reconciliação nos dois sentidos antes do commit: mudar o saldo-cache exige movimento correspondente; criar movimento exige que o saldo-cache termine exatamente igual ao saldo do ledger.
- Uma conta criada com saldo inicial diferente de zero recebe automaticamente uma transaction `adjustment` e o respectivo lançamento de abertura.
- `jl_aviator_player_state` lê o saldo pelo ledger canónico, não diretamente por `players.balance`.
- Migrations: `20260930001648_immutable_player_financial_ledger`, `20260930001729_ledger_initial_balance_posting` e `20260930001919_ledger_restrict_direct_writes`.
- Regressão permanente: `tests/sql/aviator/aviator_immutable_financial_ledger.sql`.

## Motor do voo orientado a eventos

- O multiplicador visual não faz consultas ao banco: ele é interpolado localmente a partir de `started_at` + relógio sincronizado do servidor.
- O cron global continua em 2 s porque atende também Número/Dupla, mas o ramo Aviator agora é apenas um gate leve. Uma rodada `FLYING` só chama `jl_aviator_tick` quando `engine_due_at <= clock_timestamp()`.
- Cada rodada guarda `engine_due_at`, o próximo instante financeiro relevante.
- Em `OPEN`, o próximo evento é `betting_closes_at`; em `LOCKED`, `takeoff_at`; em `FLYING`, o menor entre próximo auto cash-out ativo e crash.
- `jl_aviator_multiplier_reach_at` converte um multiplicador em timestamp exato usando a mesma curva do motor, evitando ticks para recalcular continuamente o multiplicador.
- `jl_aviator_tick` reagenda o próximo evento depois de processar os auto cash-outs devidos. Cash-out manual também reagenda porque pode alterar a exposição/target visual.
- Índice parcial `jl_aviator_bets_active_auto_due_idx` permite localizar o próximo auto cash-out apenas entre apostas ACTIVE que realmente possuem alvo automático.
- Índice `jl_aviator_rounds_engine_due_idx` permite o gate do motor localizar eventos vencidos sem varredura ampla.
- A reconciliação privada durante o voo usa `jl_aviator_bet_status(token, bet_id)`, uma consulta por PK. Ela não calcula ledger, não agrega histórico e não carrega as últimas 20 apostas.
- O limiar visual de auto cash-out não chama mais `jl_aviator_player_state`. Mudanças públicas de rodada também não fazem consulta privada para todos os jogadores; somente quem ainda possui uma aposta conhecida reconcilia seu `bet_id`.
- O `player_state` completo continua reservado para login/reconnect real, quando é necessário descobrir a aposta do jogador.
- Migrations: `20260930111947_aviator_event_driven_engine_schedule` e `20260930112207_aviator_lightweight_bet_status`.
- Regressões: `tests/sql/aviator/aviator_event_driven_engine.sql` e `tests/frontend/aviator-db-call-budget.test.cjs`.

## Animação mobile extremamente leve

- O Aviator detecta viewport móvel/pointer coarse e capacidade aproximada do aparelho (`deviceMemory`, `hardwareConcurrency` e `saveData`) para escolher um perfil visual adaptativo.
- Desktop mantém atualização visual até ~20 fps (`50 ms`). Mobile usa ~10 fps (`100 ms`) e aparelhos fracos/economia de dados usam ~8 fps (`125 ms`).
- O avião continua animado por CSS `transform: translate3d(...)`, permitindo composição pela GPU sem depender da frequência das atualizações de DOM.
- HUD secundário (bilhete, payout visual e texto do botão) é atualizado mais devagar: 250 ms no mobile e 300 ms no perfil low-power.
- O relógio visual de pré-voo caiu de 200 ms para 500 ms no mobile e 750 ms em low-power; a autoridade de tempo continua sendo o servidor.
- Quando a página fica oculta, o `requestAnimationFrame` do voo é cancelado e o relógio visual para; ao regressar, o estado autoritativo é reconciliado.
- Escritas DOM redundantes são evitadas: multiplicador, classes de tier e texto do cash-out só são alterados quando o valor realmente mudou.
- Em telas até 650 px a grid mascarada é removida, o `drop-shadow` do avião é removido, a trilha deixa de animar, sombras são reduzidas e a área de voo usa `contain: layout paint style`.
- Em low-power a trilha é removida por completo e a animação idle é desligada; a animação principal em voo permanece.
- `prefers-reduced-motion: reduce` continua tendo prioridade e desativa as animações.
- A otimização é exclusivamente visual; motor, aposta, cash-out, payout e relógio do servidor não foram alterados.
- Regressão permanente: `tests/frontend/aviator-mobile-performance.test.cjs`.

## Relógio do servidor como autoridade

- Aceitação de apostas usa exclusivamente tempo do PostgreSQL.
- O endpoint canónico captura `v_server_received_at := clock_timestamp()` e só seleciona rodada `OPEN` com `betting_closes_at > v_server_received_at`.
- O trigger `jl_aviator_server_bet_window` é uma segunda barreira no próprio `INSERT`: lê a rodada sob lock e rejeita qualquer aposta se o estado não for `OPEN`, se não existir prazo, ou se `clock_timestamp() >= betting_closes_at`.
- `jl_aviator_bets.created_at` usa `clock_timestamp()` por padrão e o trigger sobrescreve qualquer valor fornecido pelo caller. Portanto não é possível retroceder uma aposta com um relógio falsificado.
- O overload legado de 2 argumentos foi convertido em wrapper do endpoint canónico; não existe mais um caminho antigo que aceite somente por `status='OPEN'`.
- `locked_at` passou a usar `clock_timestamp()`.
- `jl_aviator_public_state().round.betting_open` usa `v_now=clock_timestamp()`. O frame de 250 ms continua apenas para suavidade visual.
- O navegador pode usar `Date.now()` para cache, retries e interpolação visual do relógio sincronizado; nunca envia horário do dispositivo no RPC de aposta e nunca determina a aceitação financeira.
- Migrations: `20260930100103_aviator_server_clock_bet_authority` e `20260930100215_aviator_server_clock_public_window`.
- Regressões: `tests/sql/aviator/aviator_server_clock_authority.sql` e `tests/frontend/aviator-server-clock.test.cjs`.

## Realtime do estado da rodada

- O estado público do Aviator é distribuído por Supabase Realtime Broadcast no tópico público `aviator:round`, evento `state`.
- O banco não transmite a linha interna de `jl_aviator_rounds`. O trigger chama `jl_aviator_public_state()` e envia apenas o payload público já filtrado; saldo da banca, reserva, limites financeiros internos, razões administrativas e outros campos privados não entram no WebSocket.
- `jl_aviator_round_realtime_state` publica em mudanças relevantes de fase/tempo/prova da rodada. `jl_aviator_settings_realtime_state` publica mudanças de manutenção/abertura.
- O frontend usa `@supabase/supabase-js@2.117.2` fixado e `js/realtime/aviator.js` para assinar Broadcast. Não usa `postgres_changes`.
- Com WebSocket saudável, o polling HTTP cai para 120 s em primeiro plano e 300 s em segundo plano, somente como reconciliação de segurança. Cada nova subscrição WebSocket força um snapshot imediato para recuperar eventos eventualmente perdidos. Sem WebSocket, o fallback é 3 s durante LOCKED/FLYING, 5 s em OPEN e 15 s nos demais estados — nunca mais 500 ms.
- O multiplicador visual é interpolado localmente com a mesma fórmula matemática do servidor (`1.06^segundos`) usando `started_at` e offset de relógio derivado de `server_time`. Isso reduz tráfego sem transferir autoridade financeira ao navegador.
- Cash-out continua a enviar apenas `bet_id` + `request_key`; o multiplicador financeiro é calculado exclusivamente no servidor no instante do cash-out.
- Auto cash-out continua executado pelo servidor; o navegador faz no máximo uma reconciliação privada quando o limiar visual é alcançado.
- A primeira conexão WebSocket cria/renova as partições diárias internas de `realtime.messages`; o projeto ainda não tinha partições no momento da migração porque não havia cliente Realtime conectado.
- Migration: `20260930094256_aviator_realtime_round_broadcast`.
- Regressões: `tests/sql/aviator/aviator_realtime_round_broadcast.sql` e `tests/frontend/aviator-realtime.test.cjs`.

## Proteção anti-bot no cash-out

- O cash-out manual possui proteção específica além do rate limiting geral.
- O frontend gera uma `request_key` estável por aposta e reutiliza a mesma chave em retries, tornando a intenção de cash-out idempotente do ponto de vista do cliente.
- O endpoint público `jl_aviator_cashout(token, bet_id, request_key)` serializa a mesma request key com advisory lock e mantém o overload antigo apenas como wrapper compatível.
- Existe limite persistente por token: 8 chamadas/10 s e 30/min. Existe também limite por aposta: 2 chamadas/s e 6/10 s.
- `jl_aviator_cashout_guard` mantém `last_attempt_at`, total de tentativas e tentativas bloqueadas por aposta. Tentativas com intervalo inferior a 250 ms retornam `BOT_TOO_FAST`.
- O core financeiro `jl_aviator_cashout_core` e o guard interno não são executáveis por `anon` nem `authenticated`; somente o wrapper público é exposto.
- Erros esperados de cash-out são convertidos em resposta estruturada dentro do wrapper. Isso faz os contadores anti-bot permanecerem gravados mesmo quando a operação financeira é rejeitada, enquanto a subtransação financeira é revertida.
- Retry de aposta já `CASHED_OUT` continua idempotente e devolve o payout/transaction já existentes; nunca cria segundo payout.
- A tabela do guard tem RLS, cliente sem acesso e `service_role` somente leitura.
- Migrations: `20260930092249_aviator_cashout_bot_and_replay_protection` e `20260930092528_cashout_guard_restrict_direct_writes`.
- Regressão permanente: `tests/sql/aviator/aviator_cashout_bot_protection.sql`.

## Rate limiting de endpoints sensíveis

- O servidor possui rate limiting por subject em `jl_api_rate_limits`, protegido por RLS e sem escrita direta pelo cliente nem pelo `service_role`.
- O limitador usa duas janelas fixas por operação: uma de burst e outra sustentada. A atualização é atómica por `INSERT ... ON CONFLICT DO UPDATE`.
- Aposta Aviator: 6 chamadas/10 s e 30/min por jogador.
- Cash-out Aviator: 8 chamadas/10 s e 30/min por jogador.
- Reconnect: 20 chamadas/10 s e 120/min por jogador, com bridge `jl_aviator_reconnect_rate_limit` que deriva o jogador do token e não expõe o helper genérico.
- Administração possui camadas: base de sessão 240/10 s e 1200/min; guard normal 60/10 s e 300/min; operações elevadas 15/10 s e 60/min; super admin 30/10 s e 120/min; session info 30/10 s e 120/min.
- O snapshot administrativo interno, acessível apenas ao `service_role`, também possui limite global de 120/10 s e 600/min.
- O login administrativo mantém o rate limit progressivo existente por origem/IP; esta camada nova protege RPCs depois da autenticação.
- Quando o limite é excedido, o servidor interrompe a chamada com `RATE_LIMITED`; o Aviator converte isso numa mensagem amigável.
- Migrations: `20260930060749_rate_limit_player_and_admin_endpoints`, `20260930060853_secure_reconnect_rate_limit_bridge` e `20260930061107_rate_limit_restrict_direct_writes`.
- Regressão permanente: `tests/sql/aviator/aviator_rate_limits.sql`.

## Payout único por aposta no banco

- O payout do Aviator é limitado a exatamente uma transação por aposta pelo próprio PostgreSQL.
- `transactions.aviator_payout_bet_id` é uma coluna `GENERATED ALWAYS`: recebe `aviator_bet_id` apenas quando `aviator_operation='PAYOUT'`; nos demais movimentos fica `NULL`.
- A constraint `transactions_one_aviator_payout_per_bet UNIQUE (aviator_payout_bet_id)` impede fisicamente um segundo payout para a mesma aposta.
- A regra não depende de JavaScript, estado do botão, retry do cliente ou apenas de locks da função de cash-out.
- As proteções anteriores continuam ativas: `payout_transaction_id` único em `jl_aviator_bets`, FK para `transactions(id)`, e unicidade por `(aviator_bet_id, aviator_operation)`.
- O teste de regressão tenta inserir um segundo payout para a mesma aposta e exige `unique_violation`.
- Migration: `20260930054913_aviator_one_payout_per_bet_constraint`.
- Regressão permanente: `tests/sql/aviator/aviator_one_payout_per_bet_constraint.sql`.

## Identificadores únicos de rodada e aposta

- Cada rodada do Aviator possui `round_no` explícito, único e imutável.
- `round_no` é uma coluna `GENERATED ALWAYS` derivada do ID interno da rodada. Isso evita uma segunda sequência que possa divergir e mantém todos os números históricos.
- Existe índice único `jl_aviator_rounds_round_no_uidx`.
- Cada aposta do Aviator possui `bet_uid UUID NOT NULL DEFAULT gen_random_uuid()`, independente do bigint interno usado nos joins.
- Existe índice único `jl_aviator_bets_bet_uid_uidx`.
- O trigger `jl_aviator_bet_uid_immutable` impede alterar o UUID de uma aposta depois de criado.
- Estado público, histórico de resultados, estado privado do jogador, colocação de aposta, cash-out e prova da rodada expõem os identificadores canónicos sem remover os IDs internos legados.
- A interface mostra `round_no` como o número da rodada; o ID interno permanece apenas para compatibilidade operacional.
- Número e Dupla já usavam UUID como PK de cada aposta e `game_rounds.global_round_no` único, portanto não precisaram de uma segunda estrutura.
- Migration: `20260930051747_aviator_unique_round_and_bet_identifiers`.
- Regressão permanente: `tests/sql/aviator/aviator_unique_round_and_bet_identifiers.sql`.

## Bloqueio de apostas concorrentes

- Existe um mutex financeiro transacional global por jogador: `jl_lock_player_wallet(player_id)`.
- O lock usa `pg_advisory_xact_lock` com chave derivada do `player_id` e permanece ativo até o fim da transação.
- O lock é obtido antes da leitura autoritativa do saldo em todos os fluxos que podem consumir dinheiro: Aviator, Número, Dupla, stake do Ludo, reentrada do Ludo e saque.
- O ajuste administrativo de saldo usa o mesmo mutex para não correr contra apostas do próprio jogador.
- Depois de adquirir o mutex, cada fluxo mantém também o `FOR UPDATE` da linha de `players`. A segunda requisição do mesmo jogador espera a primeira terminar e só então relê o saldo já atualizado.
- Resultado esperado para saldo de 100 MZN e duas requisições simultâneas de 100 MZN: apenas uma pode consumir os 100 MZN; a outra, ao prosseguir, encontra saldo insuficiente.
- O lock é interno: `anon` e `authenticated` não possuem `EXECUTE` direto.
- Migrations: `20260930050707_serialize_player_wallet_debits` e `20260930050850_serialize_admin_balance_adjustments`.
- Regressão permanente: `tests/sql/financial/player_wallet_concurrency_guard.sql`.

## Saldo confirmado pelo servidor

- O frontend nunca debita, credita ou projeta o saldo por conta própria.
- `jl_player_state`, `jl_ludo_my_status`, `jl_check_funds` e `jl_aviator_player_state` devolvem saldo calculado pelo ledger canónico e marcam a resposta com `balance_confirmed: true`.
- A interface principal e o Ludo só mostram saldo quando o snapshot recebido do servidor contém `balance_confirmed: true` e um valor numérico válido. Caso contrário, mostram `—` / `Saldo a confirmar`.
- Depois de apostas, saques, depósitos e confirmação de stake do Ludo, a interface chama novamente o servidor e só então atualiza o saldo visual.
- Foi removido do Ludo o cálculo local de “saldo depois da confirmação”. O modal mostra apenas o saldo confirmado atual e informa que o valor visual só muda após confirmação do servidor.
- Em erros de saldo insuficiente, o frontend só mostra a insuficiência exata quando o `shortfall` veio confirmado do servidor; não deduz o valor a partir de um saldo local.
- Teste permanente: `tests/point28-server-authoritative-balance.test.js`.
- Migration: `20260930005156_server_confirmed_balance_snapshots`.

## Ledger operacional da banca

- Ajustes administrativos continuam com `request_key` fornecida pelo admin.
- Lucro pago em cash-out gera `cashout:<bet_id>` com delta negativo.
- Stakes perdidos creditados no crash geram `lost-round:<round_id>` com delta positivo.
- O movimento do ledger é gravado na mesma transação do saldo da banca; falha posterior desfaz ambos.
- Movimentos operacionais de valor zero não criam linha.
- O índice único de `request_key` protege contra duplicação lógica.
- O admin consulta os movimentos por RPC separada, limitada a 50 linhas; a interface carrega 30 por vez somente ao expandir o histórico.

## Auditoria administrativa completa

Todas as ações administrativas do Aviator ficam no `audit_log` com identidade e contexto suficientes para reconstruir quem fez o quê:

- `actor_admin_id`, `actor_session_id`, nome e função do administrador.
- `target_type` e `target_id` para identificar configuração, banca ou rodada.
- `before_state` e `after_state` para mudanças de estado/configuração.
- `details` para motivo, valores, resolução financeira e metadados específicos da ação.
- Fechar e reabrir usam eventos distintos: `aviator.admin.closed` e `aviator.admin.reopened`.
- Ajuste de banca usa `aviator.admin.bank_adjusted` e exige motivo.
- Rodada de teste usa `aviator.admin.one_round_test_started`.
- Cancelamento de rodada usa `aviator.round_admin_cancelled`, com motivo e reembolsos.
- Mudança administrativa de `exposure_ratio` é capturada automaticamente como `aviator.admin.risk_limit_changed`, com valor anterior e novo.
- `jl_aviator_admin_audit_history(token, limit)` devolve até 100 ações administrativas recentes e valida a sessão de admin antes de expor a trilha.
- O painel possui a secção **Auditoria administrativa**, atualizada automaticamente enquanto estiver aberta.

Eventos do motor/jogadores continuam separados dos eventos administrativos; a visão administrativa filtra eventos do Aviator que possuem `actor_admin_id`.

## Cancelamento administrativo de rodada

O cancelamento administrativo usa `jl_aviator_admin_cancel_round(token, round_id, reason)`.

- O motivo é obrigatório, entre 5 e 240 caracteres.
- Só pode cancelar rodadas `OPEN`, `LOCKED` ou `FLYING`.
- `CRASHED`, `SETTLED` e cancelamentos já concluídos não podem ser alterados retroativamente.
- Todas as apostas `ACTIVE` são reembolsadas automaticamente e atomicamente.
- Cada reembolso gera uma transação `aviator_refund`, restaura o saldo do jogador e grava `refund_transaction_id`.
- Cash-outs já pagos permanecem válidos; não são cobrados de volta nem recebem reembolso adicional.
- O cancelamento é idempotente: repetir a mesma operação não duplica reembolsos.
- A rodada grava `admin_cancelled_at`, `admin_cancel_reason`, `admin_cancelled_by`, quantidade e total reembolsados.
- O `audit_log` guarda administrador, sessão, motivo, rodada, reembolsos e cash-outs preservados.
- O painel só habilita **Cancelar rodada e reembolsar** quando a rodada está em estado cancelável.

## Indicador financeiro da casa

O painel administrativo recebe no mesmo snapshot `jl_aviator_admin_state(token)` um bloco `house`, recalculado pelo servidor e atualizado automaticamente no painel:

- `bank_balance`: banca atual do Aviator.
- `risk_budget`: parcela da banca disponível para exposição, segundo `exposure_ratio`.
- `active_liability`: lucro máximo ainda comprometido com apostas `ACTIVE`.
- `available_after_worst_case`: banca restante se toda a responsabilidade ativa for paga no limite atual.
- `risk_usage_pct`: percentagem do orçamento de risco atualmente consumida.
- `cashout_profit_paid`: lucro já pago em cash-outs na rodada.
- `round_realized_result`: resultado realizado da casa na rodada, calculado como stakes perdidos menos lucro pago em cash-outs.
- `status`: `HEALTHY`, `ATTENTION` ou `CRITICAL`.

Os estados usam limiares conservadores: `ATTENTION` a partir de 70% do orçamento de risco e `CRITICAL` a partir de 90%, banca não positiva ou margem negativa no pior caso. O painel consulta este snapshot automaticamente a cada 3 segundos; não precisa consultar banco ou logs manualmente.

## Exposição administrativa da rodada

O snapshot `jl_aviator_admin_state(token)` entrega um bloco `exposure` calculado no servidor:

- `total_staked`: soma das apostas da rodada.
- `players`: jogadores distintos que participaram da rodada.
- `cashouts`: quantidade de apostas já encerradas por cash-out.
- `cashout_paid`: valor total já pago por cash-outs.
- `active_bets` e `active_stake`: exposição ainda aberta.
- `potential_payment`: cash-outs já pagos + máximo ainda pagável às apostas `ACTIVE` pelo limite financeiro/target atual da rodada.
- `limit_multiplier`: multiplicador limite usado nesse cálculo.

Durante `OPEN`, o limite potencial usa o teto financeiro projetado pela banca/exposição e respeita o target visual quando ele for menor. Depois do lock, usa o target efetivo congelado da rodada. O navegador apenas apresenta estes números; não calcula exposição financeira.

## Operação da banca

- Ajustes negativos da banca são bloqueados durante `LOCKED` ou `FLYING`.
- O admin mostra aviso informativo quando a banca atual implicaria teto muito baixo para uma referência de 10 MZN.
- O aviso não altera saldo e não muda a fórmula.
- Banca baixa pode produzir crash financeiro muito próximo de 1x; isso é consequência da fórmula, não erro visual.

## Estado de implantação

Em 2026-09-29, o bloco final de manutenção, histórico leve, crash lógico, estado privado limitado, alvo visual pré-comprometido, permissões, reconciliação financeira, reabertura e auto-heal foi aplicado e verificado em produção com o Aviator fechado. Novas migrations posteriores continuam exigindo aplicação e verificação explícitas.

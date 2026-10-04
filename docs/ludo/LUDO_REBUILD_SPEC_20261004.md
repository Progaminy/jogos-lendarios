# Ludo Lendário — especificação de reconstrução

Data de captura: 2026-10-04

Este documento preserva o comportamento, as regras, a geometria, o visual, os contratos de servidor e os fluxos do Ludo Lendário antes da reconstrução limpa do frontend. É a fonte de referência do produto. Não é código de execução.

## 1. Princípio da reconstrução

O frontend deve ter uma única fonte de estado, um único carregamento autoritativo e um único controlador de ecrã. Nenhum script paralelo pode forçar visibilidade, interceptar `fetch`, recriar `state.room`, executar MutationObserver para corrigir a interface, ou manter polling próprio concorrente.

Fluxo autoritativo único:

1. Ler `jl_player_token` por `JLSession`.
2. Chamar `jl_ludo_my_status`.
3. Se `active_room_id` existir, carregar `jl_ludo_room_state_light` dessa sala.
4. Carregar apenas os deltas necessários (`jl_ludo_room_delta`) para eventos, chat e payouts.
5. Aplicar `status` e `room` de forma atómica.
6. Renderizar exatamente um estado visual: `sem sessão`, `lobby`, `sala a carregar`, ou `sala ativa`.
7. Realtime apenas solicita uma nova sincronização; nunca escreve estado visual de forma independente.

Regra crítica: se o servidor já confirmou `active_room_id`, o lobby nunca pode reaparecer enquanto o snapshot da sala está em carregamento. Deve aparecer uma vista de sala/carregamento, não o tabuleiro estático do lobby.

## 2. Integração com Jogos Lendários

- Rota pública: `/ludo.html` (rota amigável `/ludo` pode apontar para a mesma página pela infraestrutura).
- Jogo isolado do catálogo; não é incorporado na home.
- Usa a conta e o saldo comuns da plataforma.
- Token de jogador: `jl_player_token`.
- API comum: `window.JLApi.rpc(name,args)`.
- Sessão comum: `window.JLSession`.
- Idioma: `pt-MZ`.
- Moeda: MZN.
- PWA: atalho “Ludo Lendário” para `/ludo.html`.

## 3. Estados do utilizador e da página

### 3.1 Sem sessão

Mostrar entrada/criação de conta e tabuleiro visual. Nunca chamar ações de sala sem token.

### 3.2 Autenticado sem sala ativa

Mostrar lobby:
- criar partida;
- entrar por código;
- ficar à espera / procurar partida;
- convites individuais;
- desafios públicos;
- jogadores online;
- conta e saldo.

### 3.3 Sala ativa conhecida, snapshot em carregamento

Mostrar a área de sala com indicação de carregamento. Não mostrar lobby. Este estado existe para impedir o bug histórico em que `active_room_id` era encontrado mas a página continuava no tabuleiro de lobby.

### 3.4 Sala ativa carregada

Mostrar:
- código da sala;
- estado da partida;
- jogadores e vagas;
- tabuleiro real;
- preparação/regras/aposta conforme o estado;
- ações válidas naquele estado;
- convite de jogadores quando permitido;
- chat/voz quando aplicável;
- resultado e revanche após o fim.

## 4. Estados da sala

Estados observados/esperados:

- `waiting`: aguardando jogadores;
- `negotiating`: regras em negociação/aceitação;
- `funding`: valor da aposta em confirmação;
- `playing`: jogo iniciado;
- `finished`: terminado;
- `cancelled`: cancelado.

A interface deve derivar tudo do estado do servidor; não inventar transições locais.

## 5. Criação da partida

Configurações disponíveis no lobby:

- Cor: vermelho, verde, amarelo, azul.
- Estilo de peão: `current` (Atual), `classic` (Pino), `video` (Escudo).
- Peões por jogador: 1, 2, 3 ou 4; padrão 4.
- Jogadores: 2, 3 ou 4; padrão 4.
- Aposta: mínimo 10 MZN, valores inteiros, passo 1 MZN; padrão 10 MZN.
- Tempo por jogada: 10, 15, 20, 25 ou 30 segundos; padrão 30.
- Modo: individual (`solo`) ou parceiros (`partners`).
- Parceiros exige exatamente 4 jogadores.
- Sala pública: ligada por padrão.

RPC principal: `jl_ludo_create_room` com `p_token`, `p_player_count`, `p_bet_amount`, `p_mode`, `p_is_public`, `p_rules`.

Também existe criação a partir de convite do tabuleiro por `jl_ludo_create_from_board_invite`.

## 6. Entrada e descoberta de partidas

- Entrar por código `LUDO-...`: `jl_ludo_join_public_room`.
- Fila: `jl_ludo_enter_queue` e `jl_ludo_leave_queue`.
- Desafios públicos: `jl_ludo_public_challenges`.
- Aceitar desafio público: `jl_ludo_accept_public_challenge`.
- Convites diretos: `jl_ludo_accept_invite`.
- Pesquisa de jogador: `jl_ludo_find_players`.
- Jogadores à espera: `jl_ludo_waiting_players`.
- Enviar convite: `jl_ludo_invite`.
- Reanunciar sala pública: `jl_ludo_rebroadcast_challenge`.

Convites públicos devem permanecer disponíveis enquanto a sala estiver aberta e houver vaga; não devem depender de cronómetros artificiais do frontend.

## 7. Cores e posicionamento

Cores canónicas do jogo:

- Vermelho: `#ef4c55`.
- Verde: `#38c783`.
- Amarelo: `#f1c843`.
- Azul: `#4c8bf5`.

Pares opostos obrigatórios em partidas de 2 jogadores:

- vermelho ↔ amarelo;
- verde ↔ azul.

Ao mudar a cor do primeiro jogador numa sala de 2, o adversário deve ser reposicionado na cor oposta. O segundo jogador também entra na cor oposta.

Em partidas de 3/4, o servidor escolhe somente uma cor realmente livre.

## 8. Geometria completa do tabuleiro

Grade: 15 × 15 = 225 células.

### 8.1 Caminho principal (52 posições)

`[[6,1],[6,2],[6,3],[6,4],[6,5],[5,6],[4,6],[3,6],[2,6],[1,6],[0,6],[0,7],[0,8],[1,8],[2,8],[3,8],[4,8],[5,8],[6,9],[6,10],[6,11],[6,12],[6,13],[6,14],[7,14],[8,14],[8,13],[8,12],[8,11],[8,10],[8,9],[9,8],[10,8],[11,8],[12,8],[13,8],[14,8],[14,7],[14,6],[13,6],[12,6],[11,6],[10,6],[9,6],[8,5],[8,4],[8,3],[8,2],[8,1],[8,0],[7,0],[6,0]]`

Índice inicial por cor:
- vermelho: 0;
- verde: 13;
- amarelo: 26;
- azul: 39.

### 8.2 Corredores de chegada

- vermelho: `[[7,1],[7,2],[7,3],[7,4],[7,5]]`;
- verde: `[[1,7],[2,7],[3,7],[4,7],[5,7]]`;
- amarelo: `[[7,13],[7,12],[7,11],[7,10],[7,9]]`;
- azul: `[[13,7],[12,7],[11,7],[10,7],[9,7]]`.

### 8.3 Posições base dos quatro peões

- vermelho: `[[1,1],[1,4],[4,1],[4,4]]`;
- verde: `[[1,10],[1,13],[4,10],[4,13]]`;
- amarelo: `[[10,10],[10,13],[13,10],[13,13]]`;
- azul: `[[10,1],[10,4],[13,1],[13,4]]`.

### 8.4 Casas seguras

Índices do caminho: `0, 8, 13, 21, 26, 34, 39, 47`.

Casas seguras estão sempre ativas. Não é permitido capturar nessas casas.

### 8.5 Passos internos

- `steps = -1`: peão na base;
- `0..50`: pista principal;
- `51..55`: corredor final da cor;
- `56`: peão concluído;
- chegada exata obrigatória: movimento que ultrapasse 56 é inválido.

Células finais de referência:
- vermelho `[7,6]`;
- verde `[6,7]`;
- amarelo `[7,8]`;
- azul `[8,7]`.

## 9. Regras de jogo

### 9.1 Saída da base

Peão só sai da base com 6.

### 9.2 Regra de 6 forçado — regra atual pretendida

A reconstrução deve seguir a regra atual definida para o produto, não a exceção antiga que ficou em testes históricos:

- contar lançamentos consecutivos sem 6 por jogador;
- depois de 6 tentativas consecutivas sem 6, o 7.º lançamento é obrigatoriamente 6;
- qualquer 6 normal ou forçado reinicia a contagem;
- não existem exceções por UUID de jogador;
- depois de 5 falhas, a interface pode avisar que faltam duas tentativas;
- depois de 6 falhas, pode avisar que o próximo 6 é garantido.

Há contrato SQL histórico no repositório que ainda descreve limiar 11 e duas exceções privilegiadas. Esse trecho é considerado obsoleto e deve ser reconciliado no backend/testes antes de ser tratado como verdade de produção.

### 9.3 Sem movimento legal após 6

Se sair 6 mas não existir movimento legal, a vez termina; não conceder jogada extra por esse 6 sem ação.

### 9.4 Três 6 seguidos

A regra de penalização de três 6 existe e, quando ativa, passa a vez.

### 9.5 Captura

- Captura devolve peão adversário à base (`steps=-1`).
- Casas seguras não permitem captura.
- Vários peões podem ocupar a mesma casa.
- Não existem bloqueios/barreiras por quantidade de peões.
- Ao cair numa casa com vários peões adversários capturáveis, todos são enviados à base.
- `capture_required` pode tornar captura obrigatória.
- Penalidade por ignorar captura pode ser: perder a vez, eliminação, ou eliminação com reentrada, conforme as regras aceites.
- Em partidas de 2 jogadores, ignorar captura obrigatória deve apenas fazer perder a vez.
- Captura pode conceder jogada extra se `capture_extra_turn` estiver ativa.

### 9.6 Parceiros

- Somente 4 jogadores.
- Equipas: posições 1+3 versus 2+4.
- `partner_capture` define se parceiros podem capturar-se.

### 9.7 Timeout

Timeout passa a vez; não elimina o jogador. Reconexão tardia continua suportada.

### 9.8 Desistência e saída

- Antes do jogo: cancelar/sair por `jl_ludo_cancel_or_leave`.
- Durante a partida: desistência explícita por `jl_ludo_forfeit`.
- Timeout não equivale a desistência.

## 10. Regras negociáveis

Campos:

- `turn_seconds` / `move_seconds`;
- `capture_required`;
- `capture_penalty`;
- `reentry_allowed`;
- `reentry_amount`;
- `partner_capture`;
- `capture_extra_turn`;
- `six_extra_turn`;
- `three_sixes_penalty`;
- `exact_finish` (deve permanecer verdadeiro no contrato principal);
- `chat_enabled`;
- `play_location`: online/presencial;
- `dice_count`: 1, 2, 3, 4.

Aceitação por versão de regras. Sem prazo artificial imposto pelo frontend. Propor mudança cria nova versão e requer nova aceitação de quem ainda não aceitou essa versão.

Quando `dice_count > 1`, a versão antiga da UI desativava as opções de jogada extra ligadas a 6/captura/três 6; a reconstrução deve refletir o que o backend efetivamente aceita e não inventar comportamento local.

## 11. Apostas e dinheiro

- Mínimo: 10 MZN.
- Apenas MZN inteiro para aposta/stake do Ludo.
- Saldo nunca pode ficar negativo.
- Entrada em sala deve validar saldo disponível.
- Confirmação de stake acontece na fase `funding`.
- Contraproposta de valor não debita saldo; débito/compromisso só após confirmação do servidor.
- Refund deve restaurar corretamente o requisito de dinheiro apostado.
- Payout é único por sala/jogador.
- Crédito só acontece depois de o payout único ser reclamado com sucesso.
- Comissão: 1% do bruto, arredondado para cima, mínimo 1 MZN, nunca acima do bruto.
- Solo: vencedor recebe pote bruto menos comissão.
- Parceiros: cada vencedor usa bruto de `pote/2`, menos a comissão individual.
- Reentrada rejeita saldo insuficiente.

## 12. Peões

Quantidade por jogador: 1..4, padrão 4.

A partida só termina quando todos os peões ativos do vencedor/equipa cumprirem a condição de chegada conforme o motor.

Estilos preservados:

1. `current` — peão atual arredondado;
2. `classic` — “Pino”;
3. `video` — “Escudo”.

As chaves internas devem permanecer essas para compatibilidade com salas antigas.

## 13. Tabuleiro e tamanho visual

Canonicalizar os valores conflitantes que surgiram em patches:

- tabuleiro desktop: máximo 680 px;
- mobile: largura 100%;
- proporção: 1:1;
- 15 colunas iguais;
- borda externa escura de aproximadamente 4 px;
- raio aproximado 10–12 px;
- peão normal: ~66% da célula;
- peões sobrepostos: ~58–60% e deslocados para permanecer clicáveis;
- peão legal: destaque amarelo/alto contraste, com `outline` e animação discreta;
- centro: composição das quatro cores;
- casas seguras: estrela visível;
- orientação pode girar/transformar visualmente para colocar a cor do jogador em posição natural, sem alterar coordenadas do motor.

## 14. Sistema visual global

Tema escuro.

Tokens canónicos:

- fundo: `#07101d`;
- painel: `#0e1a2b`;
- painel secundário: `#12233a`;
- linha: `#263b58`;
- texto: `#f4f7fb`;
- texto secundário: `#91a4bd`;
- dourado/acento: `#f4bd42`;
- vermelho: `#ef4c55`;
- verde: `#38c783`;
- amarelo: `#f1c843`;
- azul: `#4c8bf5`;
- perigo: `#ef5967`;
- sucesso: `#35c985`.

Painéis: raio aproximado 18–20 px no desktop, 14–15 px no mobile.

Controles de criação:
- botões de cor: ~58 px de altura desktop, ~52 px mobile;
- ícone da linha: ~50×50 desktop, ~40×40 mobile;
- stepper da aposta: colunas 58 / conteúdo / 58 px; mobile 48 / conteúdo / 48 px;
- botão principal JOGAR: ~56 px, mobile ~52 px;
- seletor de estilo de peão: ~78 px, mobile ~66 px;
- miniatura de peão: ~46×52, mobile ~38×43.

## 15. Dado e turno

- Dado clicável apenas quando a fase e o jogador atual permitem.
- Resultado sempre vem do servidor (`jl_ludo_roll`); nunca usar `Math.random` no cliente.
- Faces 1–6 renderizadas por pontos.
- Animação visual não pode decidir resultado.
- Resultado de Realtime pode aparecer imediatamente, mas estado completo deve ser reconciliado pelo snapshot.
- O lacre/destaque do dado acompanha a cor de quem tem a vez.
- Cronómetro deriva de `action_deadline` do servidor.

RPC de movimento: `jl_ludo_move(p_token,p_room,p_token_no)`.

## 16. Sincronização e Realtime

Canal: `ludo:room:<roomId>`.
Evento: Broadcast `sync`.

Eventos e chat no banco disparam sincronização Realtime. Evento público de `dice_rolled` inclui jogador e valores de dado.

Regras do frontend reconstruído:

- Realtime não modifica `state.room` diretamente;
- Realtime apenas chama `scheduleRefresh()`;
- somente uma sincronização pode estar em voo por vez;
- pedidos que chegarem enquanto há sincronização marcam `refreshQueued=true` e executam uma única nova sincronização depois;
- polling de segurança pode ser ~3 s quando Realtime está desligado e mais lento no lobby;
- ao voltar para a aba/foco, solicitar refresh uma única vez;
- nenhuma sequência de refresh pode invalidar a única atualização que estava prestes a renderizar a sala.

## 17. Chat, voz e som

Chat:
- envio por `jl_ludo_send_chat`;
- `chat_enabled` controla disponibilidade;
- mensagens entram por delta e podem disparar Realtime.

Voz:
- começa desligada;
- `getUserMedia` somente por ação do utilizador;
- áudio com echo cancellation/noise suppression/auto gain quando suportado;
- cada jogador controla o próprio microfone e pode silenciar adversários;
- voz indisponível após `finished`/`cancelled`.

Som:
- configuração persistida em `jl_ludo_sound_enabled`;
- som deve ser opcional e nunca alterar o estado da partida.

## 18. Resultado e revanche

Resultado mostra vencedor/payout confirmado pelo servidor.

Revanche permite alterar:
- aposta;
- tempo por jogada;
- modo;
- quantidade de peões;
- quantidade de dados;
- cor.

RPC atual: `jl_ludo_rematch_v2`.

## 19. Conta e sessão

- Login: `jl_login_player(p_phone,p_pin)`.
- Registo: `jl_register_player(p_name,p_phone,p_pin,p_invite_code)`.
- Logout: `jl_logout_player(p_token)`.
- Ludo compartilha sessão/saldo com os restantes Jogos Lendários.
- Segunda sessão/segurança são responsabilidades do backend comum; o Ludo não deve criar um sistema de sessão paralelo.

## 20. Acessibilidade e mobile

- Todos os botões de peão jogável devem ser focáveis e acionáveis por teclado.
- Elementos não jogáveis devem informar estado por ARIA, sem capturar foco desnecessário.
- Mensagens de erro importantes em região `aria-live` apropriada.
- Modais devem prender/restaurar foco via infraestrutura comum.
- Mobile não pode ocultar a sala ativa nem depender de hover.
- Nome do jogador no tabuleiro deve usar primeiro nome quando o espaço for curto.

## 21. Contratos de servidor que não devem ser apagados

A reconstrução do frontend não apaga tabelas, saldos, salas, jogadores, payouts, eventos, chat, migrations nem testes de contrato. Esses elementos preservam dados e dinheiro reais.

Entidades/contratos relevantes incluem `ludo_rooms`, `ludo_room_players`, `ludo_tokens`, `ludo_events`, `ludo_chat`, `ludo_payouts` e RPCs `jl_ludo_*`.

O admin possui espectador de sala somente leitura (`jl_admin_ludo_watch_room`) e ferramentas operacionais; elas não são parte do frontend do jogador e não devem ganhar autoridade de jogo.

## 22. Inventário legado de frontend a eliminar da rota Ludo

A implementação antiga acumulou múltiplas camadas concorrentes. Estes ficheiros/camadas não devem ser carregados pela página reconstruída e podem ser removidos após a troca:

- `ludo-authoritative-sync.js`
- `ludo-board-first.js`
- `ludo-board-ui.js`
- `ludo-challenge-fix.js`
- `ludo-collapse.js`
- `ludo-deferred.css`
- `ludo-experience.js`
- `ludo-invites-dice-fix.js`
- `ludo-policy.js`
- `ludo-preview.css`
- `ludo-pro.css`
- `ludo-pro.js`
- `ludo-public-challenges.js`
- `ludo-public-challenges-v2.js`
- `ludo-public-challenges-v3.js`
- `ludo-resilience-fix.js`
- `ludo-room-flow-v2.js`
- `ludo-rules-options-v2.js`
- `ludo-stable-ui.js`
- `ludo-sync.js`
- `js/ludo/active-room-recovery.js`
- `js/ludo/animation.js`
- `js/ludo/movement-guard.js`
- `js/ludo/policy.js`
- `js/ludo/render.js`
- `js/ludo/room-authority-v1.js`
- `js/ludo/room-state.js`
- `js/ludo/route-compat.js`
- `js/ludo/sound.js`
- `js/ludo/state.js`
- `js/ludo/voice.js`
- `js/platform/ludo-feature-loader.js`

`js/realtime/ludo.js` pode ser mantido apenas como adaptador de transporte sem autoridade de estado, ou reconstruído dentro do novo núcleo. Os utilitários comuns (`config.js`, `JLApi`, `JLSession`, header, notificações, PWA) não são implementação Ludo e devem continuar partilhados.

## 23. Padrões proibidos depois da reconstrução

- mais de um objeto de estado Ludo;
- mais de uma função que decide lobby/sala;
- script de “recovery” que altera classes por fora do render principal;
- MutationObserver global para corrigir UI;
- `setInterval` de remendo que reescreve DOM;
- monkey-patch de `window.fetch`;
- reload obrigatório para entrar numa sala;
- `location.reload()` como mecanismo normal de sincronização;
- RPC paralelo duplicado para descobrir a mesma sala;
- cache-busting usado para mascarar conflito lógico;
- resultado de dado ou movimento decidido no navegador.

## 24. Critérios mínimos de aceitação da reconstrução

1. Jogador sem sala vê lobby.
2. Jogador com `active_room_id` vê a sala, inclusive após fechar/reabrir a página.
3. A sala aparece mesmo se o snapshot levar alguns instantes; o lobby não pisca por cima.
4. Criar sala navega visualmente para a sala sem reload.
5. Entrar por código navega para a sala sem reload.
6. Aceitar convite navega para a sala sem reload.
7. Dois clientes na mesma sala recebem movimentos/turnos rapidamente e reconciliam estado.
8. Nenhuma ação financeira é duplicada por refresh concorrente.
9. Reabrir/reconectar não elimina jogador por timeout.
10. Partida de 2 jogadores mantém cores opostas.
11. Casas seguras, captura, chegada exata e ausência de bloqueio seguem o servidor.
12. Mobile mostra sala, código, convite/sair, tabuleiro e turno sem depender de scroll impossível.
13. Não existe nenhum script legado a reescrever visibilidade fora do núcleo.
14. Console não apresenta exceção de inicialização no carregamento normal.
15. A página pública em produção entrega apenas a nova cadeia de scripts do Ludo.

## 25. Fonte de verdade após esta reconstrução

- Regras e contratos: backend/Supabase + este documento.
- Estado da sessão e da sala no browser: um único objeto interno de `ludo.js`.
- Renderização: uma única função `render()` de `ludo.js`.
- Transporte: `JLApi` e Realtime, sem autoridade visual própria.
- Layout: `ludo.css`.
- Estrutura: `ludo.html`.

Qualquer nova funcionalidade deve ser incorporada nessa linha única; não criar novo script corretivo paralelo.
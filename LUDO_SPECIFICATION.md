# Ludo Lendário — especificação consolidada

Este documento é a fonte de verdade para a reconstrução do Ludo Lendário. Ele foi criado antes da remoção do frontend antigo para preservar comportamento, regras, visual, contratos de servidor e decisões de produto.

## 1. Objetivo

O Ludo Lendário é um jogo online, server-authoritative, integrado à mesma conta e ao mesmo saldo dos Jogos Lendários. Deve funcionar de forma confiável em celular e desktop, permitir recuperar uma partida após atualização/reconexão e nunca esconder permanentemente os controles de lobby quando não existe uma sala ativa válida.

Princípio central da nova implementação: **um único estado no navegador, uma única rotina de sincronização e uma única rotina de renderização**. Não usar múltiplos scripts concorrentes para recuperação, visibilidade ou autoridade de sala.

## 2. Componentes que devem ser preservados

- Conta do jogador e sessão existente.
- Saldo e carteira existentes.
- Histórico financeiro e apostas.
- Salas, partidas e eventos armazenados no Supabase.
- RPCs server-authoritative existentes enquanto forem compatíveis.
- Migrações históricas do Supabase como arquivo técnico; elas não devem ser apagadas porque fazem parte do histórico do banco.
- Integrações administrativas e de auditoria que dependam do histórico do Ludo.

A reconstrução elimina o **frontend antigo e as camadas de remendo**, não os dados financeiros/transacionais da produção.

## 3. Tabuleiro

### 3.1 Geometria

- Grade clássica de 15 × 15 células.
- Percurso externo de 52 posições.
- Passos de percurso: 0 a 50.
- Entrada na reta final: 51 a 55.
- Finalização: passo 56.
- Casas seguras do percurso: 0, 8, 13, 21, 26, 34, 39, 47.

### 3.2 Posições iniciais por cor

- Vermelho: índice 0.
- Verde: índice 13.
- Amarelo: índice 26.
- Azul: índice 39.

### 3.3 Bases

- Vermelho: canto superior esquerdo.
- Verde: canto superior direito.
- Amarelo: canto inferior direito.
- Azul: canto inferior esquerdo.

Coordenadas históricas usadas no tabuleiro 15 × 15:

- Vermelho: [1,1], [1,4], [4,1], [4,4].
- Verde: [1,10], [1,13], [4,10], [4,13].
- Amarelo: [10,10], [10,13], [13,10], [13,13].
- Azul: [10,1], [10,4], [13,1], [13,4].

### 3.4 Retas finais

- Vermelho: [7,1], [7,2], [7,3], [7,4], [7,5]; final [7,6].
- Verde: [1,7], [2,7], [3,7], [4,7], [5,7]; final [6,7].
- Amarelo: [7,13], [7,12], [7,11], [7,10], [7,9]; final [7,8].
- Azul: [13,7], [12,7], [11,7], [10,7], [9,7]; final [8,7].

### 3.5 Cores visuais

Paleta histórica consolidada:

- Fundo principal: `#07101d`.
- Painel: `#0e1a2b`.
- Painel secundário: `#12233a`.
- Linha/borda: `#263b58`.
- Texto: `#f4f7fb`.
- Texto secundário: `#91a4bd`.
- Destaque/dourado: `#f4bd42`.
- Vermelho: `#ef4c55`.
- Verde: `#38c783`.
- Amarelo: `#f1c843`.
- Azul: `#4c8bf5`.
- Perigo: `#ef5967`.
- Sucesso: `#35c985`.

A reconstrução pode melhorar contraste e responsividade, mas deve manter claramente as quatro cores do Ludo.

### 3.6 Tamanho e responsividade

- Conteúdo desktop: largura máxima aproximada de 1220 px.
- Tabuleiro desktop: máximo aproximado de 760 px.
- Tabuleiro: proporção 1:1.
- Celular: tabuleiro usa 100% da largura útil disponível.
- Painéis devem virar uma coluna no celular.
- Controles essenciais nunca podem ficar fora da viewport sem possibilidade de rolagem.
- Botões de ação devem ser tocáveis confortavelmente em Android.

## 4. Peões

- Quantidade configurável: 1, 2, 3 ou 4 peões por jogador.
- Estilos históricos suportados: atual, pino clássico e escudo/vídeo.
- Cada jogador escolhe uma cor livre antes da partida.
- Em partida de 2 jogadores, os jogadores devem ocupar cores opostas.
- O servidor é a autoridade final para cor disponível, posição e movimento.
- Se uma cor escolhida já estiver ocupada, o jogador deve receber uma cor válida ou feedback claro.

## 5. Dado

- Valores válidos: 1 a 6.
- Aparência de dado com pontos clássicos.
- Clique/toque no dado é a ação principal de lançamento.
- Resultado é definido e validado pelo servidor.
- O cliente pode animar o lançamento, mas nunca escolher o valor.
- Não reintroduzir qualquer privilégio de dado por jogador/administrador.
- Migrações antigas tiveram regras de seis forçado; a direção mais recente removeu privilégio de seis. A implementação reconstruída deve tratar o dado como server-authoritative e não manipulado no cliente.

## 6. Fluxo geral

Estados principais da sala:

1. `waiting` — aguardando participantes.
2. `negotiating` — negociação/aceitação de regras e valor.
3. `funding` — confirmação/reserva da aposta.
4. `playing` — partida ativa.
5. `finished` — partida finalizada.
6. estados de cancelamento/encerramento quando aplicáveis.

### 6.1 Inicialização do navegador

Sequência obrigatória e única:

1. Ler a sessão/token atual.
2. Se não autenticado: mostrar login e tabuleiro demonstrativo.
3. Se autenticado: chamar `jl_ludo_my_status` uma vez.
4. Se `active_room_id` existir: chamar `jl_ludo_room_state_light` para essa sala.
5. Se a sala for retornada: definir `state.room` e renderizar a sala.
6. Se não existir sala ativa: definir `state.room = null` e renderizar o lobby completo.
7. Se houver erro transitório ao recuperar uma sala: mostrar estado explícito “A recuperar partida…” e tentar novamente, sem deixar a interface presa num estado invisível.

Não deve existir um script para mostrar a sala e outro para escondê-la.

## 7. Lobby

Quando não existe sala ativa, o lobby deve estar disponível e conter:

### 7.1 Nova partida

- Cor dos peões: vermelho, verde, amarelo, azul.
- Estilo do peão: atual, pino, escudo.
- Peões por jogador: 1–4.
- Jogadores: 2, 3 ou 4.
- Aposta: valor inteiro, mínimo 10 MZN.
- Tempo de jogada: 10, 15, 20, 25 ou 30 segundos.
- Modo: individual (`solo`) ou parceiros (`partners`, 2 × 2).
- Sala pública/privada.
- Botão principal **JOGAR**.

### 7.2 Encontrar partida

- Entrada por código de sala.
- Fila/espera por partida compatível.
- Desafios públicos.
- Convites diretos.

### 7.3 Regra de disponibilidade

**Nova partida / Convidar / fluxo de lobby nunca pode desaparecer quando não existe uma sala ativa confirmada.**

Se o estado da sala ainda estiver sendo consultado, pode haver indicador de carregamento, mas o sistema não deve ficar permanentemente apenas com um tabuleiro estático.

## 8. Sala antes da partida

Deve mostrar:

- Código da sala.
- Número de jogadores.
- Modo.
- Aposta por jogador.
- Pot/premiação quando aplicável.
- Estado atual.
- Lista de jogadores e vagas.
- Cor de cada jogador.
- Estado de aceitação das regras.
- Estado de confirmação de aposta.
- Contagem/prazo quando houver deadline.
- Painel de convite para o anfitrião.
- Botão **Sair**.

### 8.1 Convidar

O anfitrião pode:

- procurar jogador por nome/código;
- ver jogadores compatíveis/à espera;
- enviar convite direto;
- copiar código da sala.

O botão/fluxo **Convidar** é essencial e não deve ser removido por mudanças de estado indevidas.

### 8.2 Sair

Antes de a partida realmente começar:

- deve existir botão explícito **Sair**;
- sair/cancelar deve usar o RPC server-authoritative;
- se houver dinheiro reservado, o servidor é responsável pelo estorno conforme regras financeiras existentes.

## 9. Negociação de regras

A sala pode negociar regras antes do início.

Comportamentos históricos que devem ser preservados quando suportados pelo backend:

- tempo por jogada;
- quantidade de peões;
- quantidade de dados quando a regra existir;
- captura obrigatória opcional;
- penalidade por ignorar captura obrigatória;
- reentrada permitida ou não;
- valor de reentrada;
- chat habilitado ou não;
- demais campos existentes no JSON de regras da sala.

Cada versão de regras possui `rules_version`.

Jogadores podem aceitar ou rejeitar uma versão; uma nova proposta gera nova versão conforme backend.

Não deve existir prazo artificial para “aceitar regras” se a regra de negócio atual não o exigir.

## 10. Aposta e dinheiro

- Unidade: MZN.
- Aposta mínima: 10 MZN.
- Valores de aposta devem ser inteiros no frontend.
- Criar/propor valor não deve retirar dinheiro automaticamente.
- Dinheiro é reservado/confirmado apenas quando o servidor confirma a aposta.
- Saldo insuficiente deve gerar mensagem clara e acesso ao depósito.
- O cliente nunca altera saldo diretamente.
- Comissão, bruto, líquido e pagamentos finais são calculados pelo servidor.
- Histórico financeiro nunca deve ser apagado pela reconstrução do frontend.

### 10.1 Contraproposta

Durante negociação, jogadores podem propor outro valor. O novo valor deve ser apresentado aos participantes para confirmação.

## 11. Início e partida

A partida só é considerada iniciada quando o backend indica `status = playing` e o estado de início correspondente está válido.

Quando começa:

- botão **Sair** deixa de ser a ação normal;
- aparece botão explícito **Desistir**;
- tabuleiro real é mostrado;
- jogador atual e tempo de jogada são mostrados;
- dado torna-se acionável apenas quando permitido;
- movimentos legais são fornecidos/validados pelo servidor.

## 12. Turnos e tempo

- Tempo de jogada configurável em 10/15/20/25/30 segundos.
- Contagem deve estar visível quando houver prazo.
- Timeout **não elimina automaticamente o jogador**.
- Timeout deve passar a vez conforme regra atual do servidor.
- Desistência é uma ação voluntária e separada do timeout.
- Desconexão temporária não deve equivaler a desistência.

## 13. Movimento

- O servidor é a autoridade para `legal_moves`.
- O cliente destaca apenas movimentos recebidos como legais.
- O cliente envia o número do peão ao RPC de movimento.
- O servidor confirma a nova posição.
- Animação é puramente visual e acontece a partir do estado confirmado.
- Nenhum movimento local deve sobreviver se contradizer o snapshot do servidor.

## 14. Captura e casas seguras

- Casas seguras permanecem protegidas.
- Captura só ocorre quando permitida pelo servidor.
- Regra histórica: se múltiplos peões adversários estiverem na mesma célula capturável, a regra atual do backend pode capturar todos conforme migração específica.
- Em partidas de 2 jogadores, regras especiais de captura/penalidade existentes no backend devem ser respeitadas.

## 15. Seis e repetição

- Tirar 6 pode conceder comportamento especial apenas conforme a regra server-authoritative atual.
- Se um 6 não possuir movimento legal, não criar artificialmente outro turno no cliente.
- O cliente não decide “seis forçado”.

## 16. Final da partida

Ao finalizar:

- mostrar vencedor/jogadores vencedores;
- mostrar pagamentos quando disponíveis: bruto, comissão da casa e líquido;
- mostrar modal/aviso de vitória;
- tocar efeitos sonoros opcionais;
- permitir revanche.

## 17. Revanche

A revanche deve permitir reutilizar/ajustar:

- valor;
- tempo;
- modo;
- quantidade de peões;
- quantidade de dados, quando suportada;
- cor;
- demais regras antes da nova aceitação.

A revanche cria nova sala/novo ciclo server-authoritative; não deve reciclar estado local antigo de forma insegura.

## 18. Reentrada

Quando regras e backend permitirem reentrada após penalidade/desconexão:

- mostrar ação explícita;
- verificar saldo no servidor;
- cobrar apenas via RPC server-authoritative;
- atualizar snapshot após sucesso.

## 19. Chat e voz

Funcionalidades existentes historicamente:

- chat por sala;
- microfone;
- mutar microfone;
- mutar adversário;
- sinalização de voz.

Esses recursos são secundários à estabilidade do núcleo. Devem ser acoplados de forma modular depois que sala, dado, turno e movimento estiverem estáveis. Nenhum módulo de voz/chat pode controlar a visibilidade do lobby ou da sala.

## 20. Social e convites

- contador de jogadores online;
- diretório/lista de jogadores;
- convites diretos;
- desafios públicos;
- integração com convite originado no tabuleiro geral;
- aceitar/recusar convite;
- não criar segunda sala ativa para o mesmo jogador.

## 21. Sessão e recuperação

- Uma conta deve possuir sessão ativa coerente com as regras de autenticação existentes.
- Um jogador não pode estar simultaneamente em várias salas Ludo ativas.
- Atualizar página, voltar do background ou perder internet não deve perder a sala.
- Recuperação usa `jl_ludo_my_status` + `jl_ludo_room_state_light`.
- A recuperação deve atualizar o **mesmo** objeto de estado usado pelo renderizador.
- Não usar MutationObserver, timers de visibilidade ou scripts paralelos para “forçar” a tela a aparecer.

## 22. Realtime e polling

Estratégia limpa:

- Snapshot inicial via RPC.
- Realtime pode disparar uma atualização, mas não modificar regras/posição diretamente.
- Um único polling de segurança com intervalo moderado enquanto existe sala ativa.
- Nunca várias rotinas concorrentes chamando `jl_ludo_my_status` ao mesmo tempo.
- Bloquear carregamento concorrente: se uma sincronização está em andamento, uma solicitação adicional vira apenas `pendingRefresh = true`.

## 23. Contratos RPC conhecidos

A reconstrução pode usar os RPCs existentes abaixo, respeitando as assinaturas atuais do servidor.

### Estado

- `jl_ludo_my_status(p_token)`
- `jl_ludo_room_state_light(p_token, p_room)`
- `jl_ludo_room_state(...)` — legado/pesado, apenas fallback se realmente necessário.
- `jl_ludo_room_delta(...)` — quando usado por sincronização incremental.
- `jl_ludo_process_timeouts(p_token, p_room)`

### Criação/entrada/fila

- `jl_ludo_create_room(p_token, p_player_count, p_bet_amount, p_mode, p_is_public, p_rules)`
- `jl_ludo_create_from_board_invite(...)`
- `jl_ludo_join_public_room(p_token, p_code)`
- `jl_ludo_enter_queue(...)`
- `jl_ludo_leave_queue(p_token)`

### Convites

- `jl_ludo_my_invites(p_token)`
- `jl_ludo_public_challenges(p_token)`
- `jl_ludo_waiting_players(p_token, p_room)`
- `jl_ludo_find_players(p_token, p_query)`
- `jl_ludo_invite(p_token, p_room, p_target_player)`
- `jl_ludo_accept_invite(...)`
- `jl_ludo_accept_public_challenge(...)`

### Preferências

- `jl_ludo_choose_color(p_token, p_room, p_color)`
- `jl_ludo_choose_pawn_style(p_token, p_room, p_pawn_style)`

### Sala/regras/aposta

- `jl_ludo_cancel_or_leave(p_token, p_room)`
- `jl_ludo_forfeit(p_token, p_room)`
- `jl_ludo_update_rules(...)`
- `jl_ludo_accept_rules(...)`
- `jl_ludo_propose_bet(...)`
- `jl_ludo_commit_stake(...)`

### Jogo

- `jl_ludo_roll(p_token, p_room)`
- `jl_ludo_move(p_token, p_room, p_token_no)`
- `jl_ludo_reenter(...)`
- `jl_ludo_rematch_v2(...)`
- `jl_ludo_send_chat(...)`

## 24. Estrutura de snapshot leve

`jl_ludo_room_state_light` devolve objeto JSON com:

- `identity`
- `room`
- `players`
- `tokens`
- `legal_moves`

`identity` inclui pelo menos `player_id`, código de jogador e número da casa.

Cada jogador da sala inclui, conforme backend atual:

- `player_id`
- `name`
- `code`
- `house_number`
- `seat`
- `color`
- `pawn_style`
- `team`
- `accepted_rules_version`
- `stake_paid`
- `stake_amount`
- `status`
- `timeout_strikes`
- `reentry_deadline`

## 25. Arquitetura obrigatória da reconstrução

Frontend novo deve ter, no máximo, estas responsabilidades centrais:

- `ludo.html`: estrutura sem lógica de estado.
- `ludo.css`: visual e responsividade.
- `ludo.js`: único controlador principal.

Dependências compartilhadas permitidas:

- `config.js`
- `js/api/rpc.js`
- `js/auth/session.js`
- componentes globais de cabeçalho/conta apenas se não interferirem no estado do Ludo.

Não reintroduzir:

- `active-room-recovery.js`
- `room-authority-v1.js`
- `route-compat.js` como mecanismo de estado
- `ludo-feature-loader.js` controlando lobby/sala
- múltiplos observadores tentando reabrir/fechar painel
- múltiplos estados `JLLudoState`
- workflows que editam automaticamente versões de scripts como solução de runtime.

## 26. Máquina de estados do frontend

Estado mínimo:

```text
session: token | null
loading: true | false
syncing: true | false
pendingRefresh: true | false
status: object | null
room: snapshot | null
error: string | null
```

Renderização é derivada exclusivamente desse estado:

- sem token → login.
- token + loading inicial → carregando.
- token + sala válida → sala.
- token + sem sala → lobby.
- erro transitório com sala previamente conhecida → manter última sala e mostrar aviso.
- erro transitório sem sala conhecida → mostrar lobby com aviso/retry; nunca tela vazia/tabuleiro isolado.

## 27. Regras de renderização essenciais

- `room !== null` ⇒ esconder lobby demonstrativo e mostrar sala.
- `room === null && autenticado` ⇒ mostrar Nova partida e Encontrar partida.
- `room.status` pré-jogo ⇒ mostrar **Sair**.
- `room.status === playing` com partida iniciada ⇒ mostrar **Desistir**.
- deadline válido ⇒ mostrar **Contagem**.
- host em `waiting`/`negotiating` ⇒ mostrar **Convidar**.
- nenhum estado válido pode resultar em “somente tabuleiro estático” para usuário autenticado.

## 28. Deploy e cache

- Não usar workflow de autoedição do HTML para cache bust.
- Usar uma versão explícita única por reconstrução, atualizada conscientemente.
- Cloudflare deve servir os arquivos do mesmo commit.
- Antes de declarar sucesso, verificar no domínio público que `ludo.html`, `ludo.css` e `ludo.js` correspondem ao commit novo.

## 29. Testes obrigatórios antes de considerar estável

1. Usuário sem sessão abre Ludo.
2. Usuário autenticado sem sala vê Nova partida.
3. Criar sala e imediatamente vê código, Sair, convidados e estado.
4. Atualizar a página dentro de sala e recuperar a mesma sala.
5. Host convida jogador.
6. Jogador aceita convite sem saldo suficiente e recebe fluxo correto de depósito.
7. Jogador aceita convite com saldo suficiente.
8. Sair antes do início.
9. Regras e contraproposta.
10. Confirmar aposta.
11. Início da partida.
12. Dado clicável apenas na vez correta.
13. Movimento legal e animação.
14. Timeout passa vez sem eliminar.
15. Desistir após início.
16. Reconexão durante partida.
17. Finalização e pagamentos.
18. Revanche.
19. Celular 360–430 px de largura.
20. Nenhuma sequência deixa jogador autenticado preso somente no tabuleiro demonstrativo.

## 30. Arquivos antigos identificados para retirada do runtime

Os seguintes arquivos pertencem ao frontend/remendos antigos e não devem permanecer referenciados pela reconstrução:

- `ludo-sync.js`
- `ludo-deferred.css`
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
- `js/realtime/ludo.js`
- `ludo-authoritative-sync.js`
- `ludo-board-first.js`
- `ludo-board-ui.js`
- `ludo-challenge-badge.js`
- `ludo-challenge-fix.js`
- `ludo-collapse.js`
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
- `.github/workflows/ludo-cache-bust.yml`

As migrações SQL históricas e testes de contrato do banco são preservados.

## 31. Critério de conclusão

A reconstrução só é considerada concluída quando:

- a implementação nova é a única implementação ativa;
- não existem loaders/guards concorrentes do Ludo antigo;
- sala ativa recupera após refresh;
- lobby aparece quando não há sala;
- Convidar/Sair/Desistir/Contagem aparecem nos estados corretos;
- partida funciona do lançamento ao resultado;
- produção foi verificada no domínio real em celular.

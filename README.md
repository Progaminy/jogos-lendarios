# Jogos Lendários

Plataforma de jogos online com **uma conta e um saldo comuns**, mas motores de jogo independentes.

## Catálogo atual

### Sorteios

1. **Número Lendário** — escolher 1 número de `0` a `10`.
2. **Dupla Lendária** — escolher 2 números diferentes de `0` a `10`.

### Tabuleiro

3. **Ludo Lendário** — 2, 3 ou 4 jogadores online; modo cada um por si ou parceiros 2×2; regras negociadas antes da aposta.

A interface pública usa categorias fixas no cabeçalho: **Todos | Sorteios | Tabuleiro | Conta**.

## Regra financeira comum

A aposta mínima de qualquer jogo é:

```text
10 MZN
```

No Ludo, a comissão da casa é **1% do ganho individual de cada vencedor**.

A comissão nunca usa valor quebrado: é sempre arredondada para cima ao metical inteiro.

```text
1% = 0,4 MZN  -> comissão 1 MZN
1% = 1,0 MZN  -> comissão 1 MZN
1% = 1,6 MZN  -> comissão 2 MZN
1% = 2,1 MZN  -> comissão 3 MZN
```

Em parceiros, o pote é dividido igualmente entre os dois vencedores e a comissão é calculada separadamente sobre a parte de cada um.

Exemplo:

```text
4 jogadores × 100 MZN = 400 MZN
parte bruta de cada vencedor = 200 MZN
1% de 200 = 2 MZN
cada vencedor recebe 198 MZN
casa recebe 2 + 2 = 4 MZN
```

## Endereços

Produção:

```text
https://jogoslendarios.adadpsf.shop
```

Administração:

```text
https://jogoslendarios.adadpsf.shop/admin.html
```

Ludo:

```text
https://jogoslendarios.adadpsf.shop/ludo.html
```

Repositório:

```text
Progaminy/jogos-lendarios
branch: main
```

Supabase:

```text
bxndjyzghgrmkelshtdp
```

# Arquitetura

```text
GitHub main
   ↓
Cloudflare Workers + Static Assets
   ↓
Frontend público + Ludo + painel admin

Supabase/PostgreSQL
   ├── jogadores e sessões
   ├── saldo comum
   ├── transações
   ├── depósitos e saques
   ├── Número Lendário
   ├── Dupla Lendária
   ├── Ludo Lendário
   └── auditoria
```

A lógica financeira e as decisões críticas ficam no **Supabase**, não no navegador.

# Número Lendário

Escolha:

```text
0..10
```

Configuração padrão:

```text
aposta mínima: 10 MZN
aposta máxima: 500 MZN
multiplicador: 10×
bloqueio: 3 segundos
```

Tabela:

```text
public.bets
```

RPC de aposta:

```text
public.jl_place_bet(text, integer, numeric)
```

Lógica do sorteio:

```text
public.jl_secure_number(uuid)
```

# Dupla Lendária

O jogador escolhe dois números diferentes de `0..10`.

```text
0 + 9 = 9 + 0
```

Existem:

```text
C(11,2) = 55 combinações
```

Configuração padrão:

```text
aposta mínima: 10 MZN
aposta máxima: 500 MZN
multiplicador: 50×
bloqueio: 3 segundos
```

Tabela:

```text
public.pair_bets
```

RPC de aposta:

```text
public.jl_place_pair_bet(text, integer, integer, numeric)
```

Lógica do sorteio:

```text
public.jl_secure_pair(uuid)
```

# Motores dos sorteios

Os jogos de números usam rodadas separadas por:

```text
game_type = number | pair
```

Motor central:

```text
public.jl_process_game_engine()
```

Fluxo:

```text
programação
→ OPEN
→ LOCKED
→ sorteio
→ pagamento
→ PUBLISHED
→ próxima rodada
```

Número e Dupla não misturam dinheiro, horário, resultado ou configuração.

# Ludo Lendário

## Entrada na sala em duas confirmações

Depois de entrar numa sala, o jogador segue um fluxo em duas janelas:

1. **Aceitar regras** — mostra a versão atual das regras e permite aceitar ou indicar que não concorda. Não há prazo para aceitar.
2. **Aceitar valor** — abre somente depois de todos terem aceite as regras e mostra o valor exato da aposta por jogador, o saldo atual e o saldo previsto após a confirmação.

As duas janelas nunca aparecem ao mesmo tempo. A segunda só aparece depois da primeira etapa estar concluída.

## Movimento automático, sons e repetir jogo

- O botão **Ligar/Desligar microfone** fica também junto ao tabuleiro, visível durante a partida. Desligar fecha de facto o microfone do aparelho; ligar volta a abri-lo.
- Se existir **apenas uma jogada legal**, o peão é movido automaticamente.
- Cada quadradinho percorrido emite um som curto.
- Capturar um peão emite um efeito próprio.
- Colocar um peão na casa final emite outro efeito e concede **nova jogada**. Com vários dados, a jogada extra fica guardada até terminar a sequência atual.
- Ao terminar a partida, toca um efeito de **foguetes/fogos de artifício**.
- Depois do resultado aparece **Repetir jogo**, mantendo os mesmos jogadores e o mesmo modo. O jogador pode ajustar a nova aposta para qualquer valor inteiro de pelo menos 10 MZN; os restantes participantes recebem convite particular.

## Regras sem prazo de aceitação

Não existe prazo para aceitar as regras de uma partida. Enquanto a sala estiver em negociação, cada jogador pode aceitar a versão atual quando quiser.

Se o anfitrião não enviar nenhuma alteração, permanecem válidas as regras padrão criadas automaticamente com a sala.

O formulário de regras não é mais sobrescrito pelo polling enquanto o anfitrião estiver a editar. Assim, escolhas como **“Se ignorar captura obrigatória”** permanecem fixas até serem enviadas ou alteradas pelo próprio utilizador.

## Notificações particulares e populares

O Ludo possui duas listas independentes de notificações:

- **Particulares:** convites enviados diretamente ao nome ou código do jogador.
- **Populares:** convites/desafios públicos disponíveis para os jogadores.

As duas listas têm contadores próprios e permanecem consultáveis mesmo quando o utilizador já está dentro de uma sala. Durante uma partida ativa, os convites continuam visíveis, mas a entrada noutra partida fica bloqueada até terminar ou desistir da atual.

## Escolha de jogadores e captura

A quantidade de jogadores é escolhida por botões fixos **2 · 3 · 4**, evitando menus expansíveis instáveis em telemóveis. No modo parceiros, a escolha é automaticamente fixada em 4 jogadores.

Durante a partida, cada jogador pode ligar ou desligar o próprio microfone a qualquer momento, desde que voz esteja permitida nas regras da sala.

A penalização por ignorar uma captura obrigatória que permite **eliminar** ou exigir **reentrada** só é válida em partidas de 3 ou 4 jogadores. Em partidas de 2 jogadores, a penalização é sempre **perder a vez**.


Arquivos principais:

```text
ludo.html
ludo.css
ludo.js
ludo-policy.js
site-nav.css
```

## Fluxo da sala

```text
jogador cria sala
→ escolhe 2, 3 ou 4 jogadores
→ escolhe solo ou parceiros
→ define aposta (mínimo 10 MZN)
→ convida por nome/código ou jogadores em espera
→ sala completa
→ negociação das regras
→ todos aceitam exatamente a mesma versão
→ fase de confirmação da aposta
→ todos pagam
→ partida começa
→ servidor controla turnos, dado, movimentos e saldo
→ resultado
→ comissão
→ pagamento
```

Se o anfitrião alterar qualquer regra, as aceitações anteriores deixam de valer e todos precisam aceitar a nova versão.

## Movimento casa a casa

Quando um peão avança, o movimento visual percorre todas as casas intermediárias em sequência rápida. Exemplo: um resultado 5 deve animar 1 → 2 → 3 → 4 → 5, sem saltar diretamente para a quinta casa.

## Resultado do dado

Todo lançamento deve permanecer visível para os jogadores, mesmo quando o valor obtido não gera movimento válido e a vez passa automaticamente. O evento `dice_rolled` é a referência visual do último lançamento quando `dice_result` já foi limpo pelo avanço de turno.

Exemplo: se a peça precisa de 6 para sair da base e o jogador tira 3, o 3 continua visível para que todos saibam qual foi o resultado.

## Timeout, reconexão e desistência

Durante uma partida em andamento, o fim do tempo de uma jogada **não elimina o jogador e não entrega vitória ao adversário**. O servidor apenas regista o atraso e passa a vez para o próximo jogador.

Uma queda de internet também não é tratada como desistência. Ao voltar e entrar novamente na mesma conta, o jogador recupera a sala ativa e encontra a partida no estado atual.

A saída voluntária durante a partida é separada: existe o botão **Desistir**. Somente essa ação explícita abandona a partida. O botão **Sair** é usado apenas antes de a partida começar.

## Tempos

As ações que dependem de um jogador nunca podem bloquear a partida indefinidamente.

Padrões atuais:

```text
convite: 60 s
aceitar regras: 60 s
confirmar aposta: 60 s
reentrada: 60 s
escolher peça: 30 s padrão
jogada: até 120 s
```

O prazo é guardado no servidor. Atualizar a página não reinicia o relógio.

## Regras negociáveis

A sala pode configurar, entre outras:

```text
saída da base: somente 6
captura obrigatória
penalização por ignorar captura
reentrada após penalização
valor da reentrada (mínimo 10 MZN)
parceiros podem ou não capturar-se
captura dá jogada extra
6 dá jogada extra
três 6 consecutivos
casas seguras
barreiras
chegada exata
limite de ausências
microfone
chat
```

## Identidade do jogador

A casa atribui um número permanente.

Exemplos:

```text
João001
João002
Amine003
```

O jogador pode ser encontrado pelo nome ou pelo código.

## Fila de espera

Um jogador pode escolher:

```text
quantidade de jogadores
modo
valor da aposta
```

e entrar em **Quero jogar**. Um anfitrião com configuração compatível pode convidá-lo.

## Motor do Ludo no Supabase

Principais tabelas:

```text
public.ludo_rooms
public.ludo_room_players
public.ludo_tokens
public.ludo_invitations
public.ludo_waiting_queue
public.ludo_events
public.ludo_chat
public.ludo_signals
public.ludo_payouts
public.ludo_player_codes
```

Principais RPCs públicas com token do jogador:

```text
jl_ludo_create_room
jl_ludo_enter_queue
jl_ludo_invite
jl_ludo_accept_invite
jl_ludo_update_rules
jl_ludo_accept_rules
jl_ludo_commit_stake
jl_ludo_roll
jl_ludo_move
jl_ludo_reenter
jl_ludo_process_timeouts
jl_ludo_room_state
jl_ludo_my_status
jl_ludo_send_chat
jl_ludo_signal_send
jl_ludo_signal_pull
```

Funções internas principais:

```text
jl_ludo_legal_moves_data
jl_ludo_advance_turn
jl_ludo_check_finish
jl_ludo_finish_room
jl_ludo_refund_room
jl_ludo_start_game
```

## Comissão do Ludo

A função responsável pelo pagamento final é:

```text
public.jl_ludo_finish_room(uuid, uuid, integer)
```

A comissão usa:

```sql
ceil(valor_bruto * 0.01)
```

com mínimo de `1 MZN`.

# Segurança

As tabelas sensíveis usam RLS e o frontend não grava diretamente nelas.

O navegador chama RPCs usando a chave pública do Supabase e o token de sessão do jogador. As funções validam esse token antes de ler ou alterar sala, saldo ou partida.

Nunca colocar no GitHub:

```text
service_role
senha do banco
chaves privadas
tokens administrativos
segredos de infraestrutura
```

# Estrutura principal

```text
jogos-lendarios/
├── index.html
├── styles.css
├── site-nav.css
├── config.js
├── app.js
├── bet-guard.js
├── ludo.html
├── ludo.css
├── ludo.js
├── ludo-policy.js
├── admin.html
├── admin.js
├── admin-power.js
├── wrangler.jsonc
└── supabase/
    └── migrations/
```

As migrações do Ludo ficam registradas no repositório com o mesmo fluxo aplicado no Supabase.

# Como clonar e testar localmente

```bash
git clone https://github.com/Progaminy/jogos-lendarios.git
cd jogos-lendarios
python3 -m http.server 8080
```

Abrir:

```text
http://localhost:8080
http://localhost:8080/ludo.html
http://localhost:8080/admin.html
```

Se já estiver clonado:

```bash
cd jogos-lendarios
git switch main
git pull origin main
python3 -m http.server 8080
```

# Fluxo de cada retificação

```text
1. git switch main
2. git pull origin main
3. criar branch quando a mudança for grande
4. alterar apenas o necessário
5. testar localmente
6. verificar git status e git diff
7. mudança de banco → criar migration
8. aplicar e testar no Supabase
9. executar auditorias de segurança/desempenho
10. git add .
11. git commit -m "Descrição clara"
12. git push
13. juntar à main depois da validação
14. Cloudflare detecta a main
15. testar produção
```

Não manter uma cópia diferente editada manualmente no Cloudflare.

# Consultas úteis

Configurações dos sorteios:

```sql
select * from public.game_settings order by game_type;
```

Salas recentes do Ludo:

```sql
select code, player_count, mode, bet_amount, pot, status, created_at
from public.ludo_rooms
order by created_at desc;
```

Jogadores de uma sala:

```sql
select room_id, player_id, seat, color, team, stake_paid, status
from public.ludo_room_players
order by room_id, seat;
```

Pagamentos do Ludo:

```sql
select room_id, player_id, gross_amount, commission, net_amount
from public.ludo_payouts
order by created_at desc;
```

# Resumo

```text
Número Lendário → Sorteios
Dupla Lendária  → Sorteios
Ludo Lendário   → Tabuleiro / Multiplayer
```

A conta e o saldo são comuns. **As regras e o motor de cada jogo permanecem independentes.**


## Confirmação visual de depósito e saque

Ao enviar um pedido de depósito ou saque, o jogador recebe uma janela central e bem visível com o tipo da operação, valor, mensagem de estado e referência do pedido quando disponível. Rejeições e erros também aparecem na mesma janela em estado de alerta, para que a resposta não dependa apenas do texto pequeno do formulário.


## Presença online e troca por convite

O Ludo mostra no topo três contadores: **jogadores online agora**, **convites individuais** e **convites populares**. A presença online usa atividade recente da sessão no Ludo, em vez de considerar toda sessão de 30 dias como conectada.

Convites individuais ficam destacados e continuam visíveis mesmo quando o jogador está dentro de uma sala. Se o jogador estiver na **sua própria sala** ainda em espera ou negociação, pode aceitar outro convite: se a sala própria estiver vazia ela é cancelada; se houver outros participantes, um deles assume como anfitrião e a sala continua aguardando completar jogadores.


## Linha de Cliente

Ao clicar no nome da conta, o jogador vê **Depósito**, **Saque**, **Mensagem** e **Sair**; o botão **Sair** é vermelho e destacado. **Mensagem** abre a Linha de Cliente, onde o jogador pode escrever dúvidas, preocupações ou problemas e acompanhar as respostas do administrador. O painel administrativo possui uma área própria com conversas por jogador, contador de mensagens não lidas e resposta direta. O histórico é armazenado no Supabase e acessado por RPC autenticada com as sessões já existentes do jogador e do admin.


## Recuperação de PIN com confirmação administrativa

O login possui **Esqueci o PIN**. O jogador informa o número da conta e um email de recuperação. O pedido não envia código imediatamente: ele aparece primeiro no painel administrativo com nome, telefone e email para o administrador ligar e confirmar a identidade. Depois da confirmação, o admin usa **Confirmar identidade e enviar código**. O serviço `jogos-recovery` gera um código de 6 dígitos, guarda somente o hash, envia por email, expira em 10 minutos e permite no máximo 5 tentativas. Ao concluir, todas as sessões antigas do jogador são revogadas e ele entra novamente com o novo PIN.

O remetente definido é `escolalendaria07@gmail.com`, o mesmo usado pela Escola Lendária. Para o envio funcionar no projeto Supabase dos Jogos, a credencial de aplicação desse Gmail deve existir no segredo `PSF_RECOVERY_EMAIL_APP_PASSWORD`. A palavra-passe nunca deve ser gravada no repositório ou no frontend.


## Bónus para Número e Dupla

O admin pode distribuir bónus para **Número Lendário**, **Dupla Lendária** ou **ambos**, escolher o tipo (Promocional, Boas-vindas, Fidelidade, Compensação ou Manual), definir um valor inteiro e selecionar um ou vários jogadores.

O bónus fica fora do saldo normal e não pode ser sacado diretamente. Ao apostar num jogo elegível, o sistema consome primeiro o bónus e usa saldo normal apenas se a aposta ultrapassar o bónus disponível. Cada aposta guarda separadamente `cash_amount` e `bonus_amount`. Quando uma aposta financiada por bónus é premiada, o prémio entra no saldo normal, pois o bónus já foi efetivamente jogado.

O jogador vê **Saldo disponível** e **Bónus para jogar** separados, com detalhamento para Número e Dupla. O histórico mostra quando uma aposta usou bónus. O admin vê saldos de bónus e as distribuições recentes.


## Depósito deve ser jogado antes do saque

Todo depósito aprovado cria um requisito de jogo igual ao valor depositado. Enquanto esse requisito não for reduzido a zero, essa parte do saldo não é sacável.

Apostas em **Número Lendário**, **Dupla Lendária** e **Ludo** reduzem o requisito apenas pelo valor efetivamente pago com saldo normal; bónus não conta como depósito jogado. No Ludo, se a aposta for devolvida porque a partida não chegou a começar, o requisito correspondente é restaurado.

O jogador vê separadamente o **saldo disponível para saque** e o **depósito ainda por jogar**. O admin também vê estes valores. O pedido de saque e a aprovação administrativa revalidam o bloqueio.

A migração reconstrói os depósitos históricos cronologicamente, descontando apenas apostas feitas depois da aprovação de cada depósito. Na aplicação inicial foram encontrados 1.091 MZN em depósitos aprovados: 650 MZN já tinham sido jogados e 441 MZN permaneceram bloqueados até serem apostados.


## Verificação de saldo antes de movimentos com valor

Antes de qualquer ação financeira do jogador, a plataforma verifica se há fundos suficientes. Isso cobre **Número Lendário**, **Dupla Lendária**, **Ludo**, criação de sala, entrada na fila, convites, desafios públicos, confirmação da aposta, reentrada, repetir jogo e saque.

- **Número e Dupla:** saldo normal + bónus elegível para o jogo contam como fundos disponíveis.
- **Ludo:** usa apenas saldo normal.
- **Saque:** usa apenas o saldo realmente sacável, respeitando depósitos ainda não jogados.
- Quando falta saldo normal, o jogador é levado diretamente para **Depósito**, e o campo de depósito é preenchido com o valor que falta.
- Se o problema do saque for um depósito ainda não jogado, a plataforma não manda depositar mais; informa que esse valor precisa primeiro ser jogado.

O backend também repete a validação para impedir que o controlo seja contornado pelo navegador. Ao entrar por convite ou desafio público, a verificação acontece antes de abandonar ou transferir a sala atual.

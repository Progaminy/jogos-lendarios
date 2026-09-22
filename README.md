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
saída da base: somente 6 ou 1/6
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

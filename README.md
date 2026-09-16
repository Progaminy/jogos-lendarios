# Jogos Lendários

Plataforma com **dois jogos independentes** que partilham apenas a conta e o saldo do jogador:

1. **Número Lendário** — escolher 1 número de `0` a `10`.
2. **Dupla Lendária** — escolher 2 números diferentes de `1` a `10`; a ordem não importa.

Cada jogo possui as suas próprias apostas, rodadas, horários, bloqueio, resultado, multiplicador, limites de aposta, modo de sorteio e estado ativo/desativado.

## Endereços

Produção:

```text
https://jogoslendarios.adadpsf.shop
```

Administração:

```text
https://jogoslendarios.adadpsf.shop/admin.html
```

URL técnica:

```text
https://jogos-lendarios.pensadorsemfronteiras0.workers.dev
```

# Arquitetura

```text
GitHub — Progaminy/jogos-lendarios — branch main
        │
        ▼
Cloudflare Workers + Static Assets
        │
        ▼
jogoslendarios.adadpsf.shop

Supabase/PostgreSQL
        │
        ├── jogadores e sessões
        ├── saldo comum do jogador
        ├── apostas Número Lendário
        ├── apostas Dupla Lendária
        ├── rodadas independentes por game_type
        ├── programação independente por game_type
        ├── configurações independentes
        ├── depósitos e saques
        ├── transações
        └── auditoria
```

A branch `main` é a fonte oficial do frontend e das migrations. O Supabase é a fonte oficial dos dados e da lógica real.

# Princípio central: dois jogos realmente separados

Os jogos **não usam a mesma rodada**.

```text
Número Lendário                  Dupla Lendária
-----------------                ----------------
rodada própria                   rodada própria
horário próprio                  horário próprio
apostas próprias                 apostas próprias
resultado próprio                resultado próprio
configuração própria             configuração própria
programação própria              programação própria
```

Exemplo:

```text
Número Lendário
rodada #30
sorteio: 18:00
resultado: 7

Dupla Lendária
rodada #31
sorteio: 18:15
resultado: 1 + 9
```

Um jogo pode estar aberto enquanto o outro está fechado. O administrador também pode programar intervalos completamente diferentes.

A única parte comum é a **conta/saldo do jogador**. Se uma aposta custa 20 MZN, esses 20 MZN são retirados do mesmo saldo, independentemente do jogo escolhido.

# Identificação das rodadas

`public.game_rounds` possui:

```text
game_type = number | pair
```

Assim, uma rodada pertence apenas a um jogo.

A programação em `public.draw_schedule` também possui `game_type`.

O mesmo horário pode existir para os dois jogos porque a unicidade é:

```text
(game_type, draw_at)
```

# Configuração independente

Tabela:

```text
public.game_settings
```

Existe uma linha para cada jogo:

```text
number
pair
```

Campos:

```text
game_type
min_bet
max_bet
multiplier
lock_seconds
draw_mode
enabled
updated_at
```

Configuração inicial:

```text
Número Lendário
mínimo:       10 MZN
máximo:       500 MZN
multiplicador: 10×
bloqueio:      3 segundos
modo:          house_min
ativo:         sim

Dupla Lendária
mínimo:       10 MZN
máximo:       500 MZN
multiplicador: 50×
bloqueio:      3 segundos
modo:          house_min
ativo:         sim
```

O administrador pode alterar cada conjunto separadamente quando o jogo não tiver rodada ativa.

Função:

```text
jl_admin_update_game_settings(...)
```

# Modos de sorteio

Cada jogo pode usar um modo diferente.

## `house_min` — menor exposição

O sistema calcula quanto a casa teria de pagar para cada resultado possível e escolhe apenas os resultados com **menor exposição**.

Se houver empate entre vários resultados com a mesma menor exposição, a escolha entre eles é aleatória por geração criptográfica.

## `house_safe_random` — aleatório entre resultados seguros

O sistema cria a lista de todos os resultados cujo pagamento vencedor continua abaixo do total arrecadado naquela rodada.

Depois sorteia aleatoriamente entre esses resultados seguros.

A regra matemática usada é:

```text
exposição_do_resultado × multiplicador < total_apostado_na_rodada
```

O sinal é estritamente `<`, não `<=`, para a rodada não terminar empatada.

# Proteção da casa antes de aceitar uma aposta

A proteção não existe apenas na hora do sorteio.

Antes de gravar uma nova aposta, o Supabase simula o estado da rodada depois daquela aposta.

Se a nova aposta fizer desaparecer a última opção que mantém:

```text
pagamento < total arrecadado
```

a aposta é recusada.

Mensagem típica:

```text
Esta aposta atingiria o limite de segurança da rodada.
```

No Número Lendário, o jogador pode então escolher outro número.

Na Dupla Lendária, pode escolher outra combinação ou aguardar a próxima rodada.

Essa regra é calculada **separadamente dentro de cada jogo**. Receita ou exposição do Número Lendário nunca é usada para cobrir a Dupla Lendária e vice-versa.

# Jogo 1 — Número Lendário

## Regra

O jogador escolhe um número de:

```text
0 a 10
```

Aposta inicial configurada:

```text
10 a 500 MZN
```

Multiplicador inicial:

```text
10×
```

Exemplo:

```text
aposta: 20 MZN
número: 7
resultado: 7
prémio: 20 × 10 = 200 MZN
```

## Tabela de apostas

```text
public.bets
```

Campos principais:

```text
id
round_id
player_id
selected_number
amount
won
payout
created_at
```

## RPC de aposta

```text
public.jl_place_bet(text, integer, numeric)
```

Valida:

```text
jogo number ativo
número 0..10
mínimo/máximo configurado
rodada number aberta
horário de bloqueio ainda não atingido
jogador autenticado
jogador não bloqueado
saldo suficiente
regra de segurança da casa
```

Depois:

```text
desconta saldo
→ grava public.bets
→ grava transactions(kind='bet')
```

## Sorteio

Função:

```text
public.jl_secure_number(round_id)
```

No modo `house_min`:

```text
somar apostas em cada número 0..10
        ↓
encontrar menor exposição
        ↓
formar lista dos números empatados
        ↓
sortear aleatoriamente dentro dessa lista
```

No modo `house_safe_random`:

```text
calcular todos os números seguros
        ↓
exposição × multiplicador < total da rodada
        ↓
sortear aleatoriamente entre os seguros
```

# Jogo 2 — Dupla Lendária

## Regra

O jogador escolhe **dois números diferentes de 1 a 10**.

A ordem não importa:

```text
1 + 9 = 9 + 1
2 + 7 = 7 + 2
```

A combinação é normalizada pelo banco:

```text
number_a = menor número
number_b = maior número
```

Logo:

```text
9 + 1
```

é guardado como:

```text
1 + 9
```

Não é permitido:

```text
5 + 5
```

Com dois números diferentes de 1 a 10 existem:

```text
C(10,2) = 45 combinações
```

Multiplicador inicial:

```text
50×
```

Exemplo:

```text
aposta: 10 MZN
combinação: 1 + 9
resultado: 1 + 9
prémio: 10 × 50 = 500 MZN
```

## Tabela de apostas

```text
public.pair_bets
```

Campos:

```text
id
round_id
player_id
number_a
number_b
amount
won
payout
created_at
```

A tabela exige:

```text
number_a < number_b
```

## RPC de aposta

```text
public.jl_place_pair_bet(text, integer, integer, numeric)
```

Valida:

```text
jogo pair ativo
dois números 1..10
números diferentes
mínimo/máximo configurado
rodada pair aberta
horário de bloqueio ainda não atingido
jogador autenticado
jogador não bloqueado
saldo suficiente
regra de segurança da casa
```

## Sorteio

Função:

```text
public.jl_secure_pair(round_id)
```

No modo `house_min`:

```text
calcular exposição das 45 combinações
        ↓
encontrar menor exposição
        ↓
formar lista das combinações empatadas
        ↓
sortear aleatoriamente dentro dessa lista
```

No modo `house_safe_random`:

```text
listar combinações em que
exposição × multiplicador < total apostado
        ↓
sortear aleatoriamente entre elas
```

A aleatoriedade interna usa `extensions.gen_random_bytes(...)` e `jl_random_index(...)` com rejeição antes do módulo para evitar viés de distribuição.

# Resultados independentes

Uma rodada `number` usa:

```text
drawn_number
```

Uma rodada `pair` usa:

```text
pair_drawn_a
pair_drawn_b
```

O frontend consulta:

```text
jl_public_state()
```

que devolve:

```text
games.number
    settings
    current_round
    last_result

games.pair
    settings
    current_round
    last_result
```

Assim os dois relógios e resultados são independentes.

# Motor automático

Motor geral:

```text
jl_process_game_engine()
```

Ele processa separadamente:

```text
jl_process_game('number')
jl_process_game('pair')
```

Cada jogo possui advisory lock próprio para impedir processamento duplicado e permitir que um motor não bloqueie o outro.

Fluxo de cada jogo:

```text
programação desse jogo
        ↓
rodada OPEN
        ↓
closes_at
        ↓
rodada LOCKED
        ↓
draw_at
        ↓
sorteio desse jogo
        ↓
pagamento desse jogo
        ↓
PUBLISHED
        ↓
próxima rodada programada desse jogo
```

# Administração independente

No painel administrativo existem dois blocos.

## Número Lendário

Pode configurar separadamente:

```text
ativo/desativado
aposta mínima
aposta máxima
multiplicador
segundos de bloqueio
modo de sorteio
rodada manual
programação de horários
horário avulso
encerrar/sortear agora
estatísticas por número
últimas apostas
```

## Dupla Lendária

Possui exactamente o mesmo tipo de controlo, mas aplicado somente à Dupla:

```text
ativo/desativado
aposta mínima
aposta máxima
multiplicador
segundos de bloqueio
modo de sorteio
rodada manual
programação própria
horário avulso
encerrar/sortear agora
estatísticas por combinação
últimas apostas
```

Exemplo de configuração independente:

```text
Número Lendário
sorteios: de 30 em 30 minutos
multiplicador: 10×
modo: house_min

Dupla Lendária
sorteios: de 60 em 60 minutos
multiplicador: 50×
modo: house_safe_random
```

Isto é válido porque são dois jogos diferentes.

# Funções administrativas principais

```text
jl_admin_update_game_settings(...)
jl_admin_open_game_round(...)
jl_admin_schedule_game_draws(...)
jl_admin_add_game_draw_time(...)
jl_admin_cancel_game_draw_time(...)
jl_admin_clear_game_schedule(...)
jl_admin_close_game_round(...)
```

Todas recebem `game_type` para saber qual jogo alterar.

As funções antigas sem `game_type` permanecem como wrappers do **Número Lendário** para compatibilidade.

# Saldo insuficiente

Se o jogador clicar em Apostar e não tiver saldo suficiente:

```text
aposta não é gravada
        ↓
frontend informa saldo insuficiente
        ↓
página desloca para Depósito
```

Isto funciona nos dois jogos.

# Depósitos e saques

Depósito:

```text
jogador solicita
→ pending
→ admin aprova/rejeita
→ aprovado aumenta saldo comum
```

Saque:

```text
saldo insuficiente
→ rejeição automática

saldo suficiente
→ valor reservado
→ pending
→ admin aprova/rejeita
```

O saldo é comum à conta, mas as apostas continuam pertencendo ao jogo específico.

# Estrutura principal

```text
players
player_sessions
game_settings
game_rounds
draw_schedule
bets
pair_bets
deposit_requests
withdrawal_requests
transactions
admin_sessions
admin_config
audit_log
```

# Migrations principais

```text
supabase/migrations/
├── 20260916_scheduled_rounds_with_three_second_lock.sql
├── 20260916_add_locked_round_state.sql
├── 20260916_bet_limits_10_500.sql
├── 20260916_add_dupla_lendaria_game.sql
└── 20260916_separate_number_pair_games.sql
```

A migration `20260916_separate_number_pair_games.sql` é a responsável por transformar os jogos em motores independentes e adicionar `game_settings`.

# Como verificar no Supabase

Configurações:

```sql
select *
from public.game_settings
order by game_type;
```

Rodadas por jogo:

```sql
select
  game_type,
  round_no,
  status,
  opened_at,
  closes_at,
  draw_at,
  drawn_number,
  pair_drawn_a,
  pair_drawn_b
from public.game_rounds
order by opened_at desc;
```

Programação:

```sql
select game_type, draw_at, status, round_id
from public.draw_schedule
order by draw_at;
```

Função do Número:

```sql
select pg_get_functiondef(
  'public.jl_secure_number(uuid)'::regprocedure
);
```

Função da Dupla:

```sql
select pg_get_functiondef(
  'public.jl_secure_pair(uuid)'::regprocedure
);
```

Motor:

```sql
select pg_get_functiondef(
  'public.jl_process_game(text)'::regprocedure
);
```

# Como clonar e testar localmente

```bash
git clone https://github.com/Progaminy/jogos-lendarios.git
cd jogos-lendarios
python3 -m http.server 8080
```

Abrir:

```text
http://localhost:8080
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
3. alterar somente o necessário
4. testar localmente
5. git status
6. git diff
7. criar migration se mudar lógica/banco
8. aplicar migration no Supabase
9. git add .
10. git commit
11. git push origin main
12. Cloudflare implanta
13. testar produção
14. testar painel administrativo
15. testar Supabase
```

# Produção

```text
GitHub:     Progaminy/jogos-lendarios
Branch:     main
Cloudflare: Worker jogos-lendarios
Domínio:    jogoslendarios.adadpsf.shop
Supabase:   bxndjyzghgrmkelshtdp
```

Não editar uma cópia diferente manualmente no Cloudflare.

Fluxo esperado:

```text
main
 ↓
push
 ↓
Cloudflare
 ↓
deploy
 ↓
produção
```

# Segurança

`config.js` pode conter somente valores públicos necessários ao navegador, como URL do Supabase e publishable key.

Nunca colocar no GitHub:

```text
service_role
senha do banco
chaves privadas
tokens administrativos
segredos de infraestrutura
```

As decisões de saldo, aposta, exposição, sorteio e pagamento ficam no Supabase e não apenas no JavaScript do navegador.

# Regra operacional final

```text
                 CONTA DO JOGADOR
                        │
                  saldo comum
                 ┌──────┴──────┐
                 │             │
                 ▼             ▼
        NÚMERO LENDÁRIO   DUPLA LENDÁRIA
        rodadas próprias   rodadas próprias
        horários próprios  horários próprios
        apostas próprias   apostas próprias
        regras próprias    regras próprias
        resultado próprio  resultado próprio
                 │             │
                 └──────┬──────┘
                        │
              pagamentos no saldo
```

**Nunca misturar a exposição financeira, o resultado ou a programação dos dois jogos. Cada motor deve ser capaz de funcionar sozinho.**

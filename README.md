# Jogos Lendários

Projeto com dois jogos na mesma plataforma:

1. **Número Lendário** — escolher 1 número de `0` a `10`; prémio de **10×** o valor apostado.
2. **Dupla Lendária** — escolher 2 números diferentes de `1` a `10`; prémio de **50×** o valor apostado quando a combinação inteira é acertada.

O frontend fica no GitHub/Cloudflare e a lógica sensível fica no Supabase/PostgreSQL.

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

## Arquitetura

```text
GitHub — Progaminy/jogos-lendarios — branch main
        │
        │ fonte oficial do frontend e migrations
        ▼
Cloudflare Workers + Static Assets
        │
        ▼
jogoslendarios.adadpsf.shop

Supabase
        │
        ├── jogadores e sessões
        ├── saldos
        ├── apostas do Número Lendário
        ├── apostas da Dupla Lendária
        ├── depósitos e saques
        ├── rodadas
        ├── programação de sorteios
        ├── transações
        ├── auditoria
        └── lógica real dos jogos
```

A branch `main` é a fonte oficial do frontend. O Supabase é a fonte oficial dos dados e da lógica do banco. Não manter cópias diferentes do site editadas manualmente no Cloudflare.

# Estrutura do projeto

```text
jogos-lendarios/
├── index.html
├── styles.css
├── config.js
├── app.js
├── bet-guard.js
├── admin.html
├── admin.js
├── admin-pair.js
├── wrangler.jsonc
├── .assetsignore
├── .gitignore
├── .nojekyll
├── supabase/
│   └── migrations/
│       ├── 20260916_scheduled_rounds_with_three_second_lock.sql
│       ├── 20260916_add_locked_round_state.sql
│       ├── 20260916_bet_limits_10_500.sql
│       └── 20260916_add_dupla_lendaria_game.sql
└── README.md
```

Não existe backend Node separado. O frontend é HTML/CSS/JavaScript estático. A lógica sensível fica no Supabase/PostgreSQL.

# Regras comuns aos dois jogos

Cada aposta deve ser:

```text
mínimo = 10 MZN
máximo = 500 MZN
```

A validação existe no navegador e também no Supabase. Portanto, chamar a API diretamente não permite contornar o limite.

Se o jogador clicar em **Apostar** com saldo insuficiente, o frontend leva automaticamente para a área de **Depósito**. Mesmo que o saldo mude entre a leitura da página e a gravação da aposta, uma rejeição `Saldo insuficiente` devolvida pelo Supabase também direciona para o depósito.

Os dois jogos usam a **mesma rodada** e o mesmo horário de bloqueio/sorteio.

# Jogo 1 — Número Lendário

## Regra

O jogador escolhe **um número de 0 a 10**.

Exemplo:

```text
número escolhido: 7
aposta: 20 MZN
```

Se o resultado do Número Lendário for `7`:

```text
20 × 10 = 200 MZN
```

O prémio creditado é **10× o valor apostado**.

## Onde as apostas ficam guardadas

Tabela:

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

Cada aposta é uma linha individual.

Exemplo:

```text
Jogador A → número 0 → 100 MZN
Jogador B → número 0 →  50 MZN
Jogador C → número 7 →  20 MZN
```

Total apostado no número `0`:

```text
100 + 50 = 150 MZN
```

## Função que grava a aposta

```text
public.jl_place_bet(text, integer, numeric)
```

Ela valida:

```text
número entre 0 e 10
valor entre 10 e 500 MZN
rodada OPEN
closes_at ainda no futuro
jogador autenticado
jogador não bloqueado
saldo suficiente
```

Depois:

```text
desconta saldo
→ grava em public.bets
→ grava transação kind='bet'
```

Para ver a função real ativa:

```sql
select pg_get_functiondef(
  'public.jl_place_bet(text,integer,numeric)'::regprocedure
);
```

# Lógica do sorteio do Número Lendário

Função:

```text
public.jl_secure_number()
```

A lógica atual **não sorteia diretamente entre todos os números de 0 a 10**.

Primeiro calcula o total apostado em cada número da rodada ativa:

```text
0  → total apostado no 0
1  → total apostado no 1
...
10 → total apostado no 10
```

Depois encontra o menor total.

Exemplo:

```text
0 → 500 MZN
1 → 100 MZN
2 → 100 MZN
3 → 300 MZN
...
```

O menor total é `100 MZN`, então os candidatos são:

```text
1 e 2
```

Entre os candidatos empatados no menor total, `extensions.gen_random_bytes(1)` escolhe de forma aleatória. A função usa rejeição antes do módulo para não favorecer uma posição quando a quantidade de candidatos não divide `256` exatamente.

Fluxo:

```text
rodada OPEN ou LOCKED
      ↓
calcular SUM(amount) de 0..10
      ↓
encontrar menor total
      ↓
criar lista dos números empatados no menor total
      ↓
gerar byte criptográfico
      ↓
escolher uniformemente dentro dessa lista
      ↓
retornar drawn_number
```

**Os valores apostados influenciam quais números entram na lista de candidatos do Número Lendário.**

Para ver exatamente o código:

```sql
select pg_get_functiondef(
  'public.jl_secure_number()'::regprocedure
);
```

# Jogo 2 — Dupla Lendária

## Regra

O jogador escolhe **dois números diferentes de 1 a 10**.

A ordem não importa.

Portanto:

```text
1 + 9 = 9 + 1
2 + 7 = 7 + 2
```

Internamente a combinação é sempre guardada em ordem crescente:

```text
9 + 1 → 1 + 9
7 + 2 → 2 + 7
```

Não é permitido escolher o mesmo número duas vezes:

```text
5 + 5 → inválido
```

Existem exatamente:

```text
C(10,2) = 45 combinações
```

## Prémio

O prémio é **50× o valor apostado**.

Exemplo pedido para a regra do jogo:

```text
aposta = 10 MZN
combinação = 1 + 9
resultado = 1 + 9
prémio = 10 × 50 = 500 MZN
```

Outro exemplo:

```text
aposta = 100 MZN
prémio = 100 × 50 = 5 000 MZN
```

## Mesma combinação independentemente da ordem

A RPC recebe dois números, mas normaliza:

```text
number_a = LEAST(p_number_a, p_number_b)
number_b = GREATEST(p_number_a, p_number_b)
```

Assim, se o jogador enviar:

```text
9 e 1
```

o banco grava:

```text
1 e 9
```

Isso impede que `1+9` e `9+1` sejam tratadas como apostas diferentes.

## Onde as apostas ficam guardadas

Tabela:

```text
public.pair_bets
```

Campos principais:

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

Existe uma restrição de banco:

```text
number_a < number_b
```

Portanto a própria tabela exige a forma canónica da combinação.

## Função que grava a aposta

```text
public.jl_place_pair_bet(text, integer, integer, numeric)
```

Ela valida:

```text
dois números informados
ambos entre 1 e 10
números diferentes
valor entre 10 e 500 MZN
rodada OPEN
closes_at ainda no futuro
jogador autenticado
jogador não bloqueado
saldo suficiente
```

Depois:

```text
normaliza a combinação
→ desconta saldo
→ grava em public.pair_bets
→ grava transação kind='bet'
```

Para ver a função:

```sql
select pg_get_functiondef(
  'public.jl_place_pair_bet(text,integer,integer,numeric)'::regprocedure
);
```

# Lógica do sorteio da Dupla Lendária

Função:

```text
public.jl_secure_pair(uuid)
```

Neste jogo o resultado é sorteado **uniformemente entre as 45 combinações possíveis**, sem usar o total apostado em cada combinação para escolher o resultado.

Combinações possíveis começam assim:

```text
1+2
1+3
1+4
...
1+10
2+3
2+4
...
9+10
```

São `45` no total.

A função usa um byte de `extensions.gen_random_bytes(1)`.

Como `256` não é divisível por `45`, usar diretamente:

```text
byte % 45
```

criaria um pequeno viés.

Para evitar isso, a função aceita somente bytes de `0` a `224`, porque:

```text
225 = 45 × 5
```

Valores `225..255` são descartados e outro byte é gerado.

Depois:

```text
índice = (byte % 45) + 1
```

Esse índice escolhe uma das 45 combinações ordenadas.

Fluxo:

```text
rodada válida
      ↓
criar universo das 45 combinações 1..10 com a < b
      ↓
gerar byte criptográfico
      ↓
byte < 225 ?
   ↓ não      ↓ sim
repetir       módulo 45
                 ↓
          selecionar combinação
                 ↓
          pair_drawn_a + pair_drawn_b
```

Para ver a função:

```sql
select pg_get_functiondef(
  'public.jl_secure_pair(uuid)'::regprocedure
);
```

# Resultado de cada rodada

A tabela:

```text
public.game_rounds
```

guarda agora dois resultados independentes:

```text
drawn_number   → resultado do Número Lendário
pair_drawn_a   → primeiro número da Dupla Lendária
pair_drawn_b   → segundo número da Dupla Lendária
```

Exemplo:

```text
Rodada 20
Número Lendário: 7
Dupla Lendária: 1 + 9
```

Um jogador pode apostar em apenas um jogo ou nos dois durante a mesma rodada.

# Bloqueio de 3 segundos

Cada rodada tem:

```text
closes_at = instante em que novas apostas ficam bloqueadas
draw_at   = instante do sorteio
```

Regra:

```text
draw_at - closes_at = 3 segundos
```

Exemplo:

```text
Sorteio: 14:00:00
Bloqueio: 13:59:57
```

Estados:

```text
OPEN
  ↓
closes_at
  ↓
LOCKED
  ↓
3 segundos
  ↓
draw_at
  ↓
PUBLISHED
```

Durante `LOCKED`, **nenhum dos dois jogos aceita novas apostas**.

A proteção real está no Supabase. `jl_place_bet(...)` e `jl_place_pair_bet(...)` exigem rodada `open` e `closes_at > now()`.

# Finalização e pagamentos

Função central:

```text
public.jl_finalize_due_rounds()
```

Quando:

```sql
draw_at <= now()
```

ela executa:

```text
jl_secure_number()
      ↓
resultado Número Lendário
      ↓
10× para quem acertou

jl_secure_pair(round_id)
      ↓
resultado Dupla Lendária
      ↓
50× para quem acertou os dois números
```

Depois soma os prémios de cada jogador, credita o saldo, grava transações de `payout`, registra `audit_log`, marca a programação como concluída e publica a rodada.

Para ver a função:

```sql
select pg_get_functiondef(
  'public.jl_finalize_due_rounds()'::regprocedure
);
```

# Motor automático

Função:

```text
public.jl_process_game_engine()
```

O Cron do Supabase executa:

```text
jogos_lendarios_engine
```

com intervalo atual:

```text
1 second
```

Fluxo:

```text
rodada OPEN
      ↓
closes_at chegou?
      ↓ sim
status = LOCKED
      ↓
draw_at chegou?
      ↓ sim
jl_finalize_due_rounds()
      ↓
sorteia Número Lendário
      ↓
sorteia Dupla Lendária
      ↓
calcula e credita prémios
      ↓
status = PUBLISHED
      ↓
schedule = completed
      ↓
jl_open_next_scheduled_round()
      ↓
próxima rodada OPEN
```

O motor usa `pg_try_advisory_xact_lock(...)` para evitar duas execuções concorrentes abrirem duas rodadas.

`jl_public_state()` e `jl_admin_dashboard()` também chamam o motor, então acessos ao site ajudam a processar transições pendentes além do Cron.

# Programação de sorteios

Tabela:

```text
public.draw_schedule
```

Campos principais:

```text
id
draw_at
status
round_id
created_at
updated_at
```

Estados:

```text
pending   → aguardando
active    → ligado à rodada atual
completed → sorteio concluído
cancelled → cancelado pelo admin
missed    → horário passou sem ativação
```

O administrador pode:

```text
abrir uma rodada manual
programar várias rodadas
escolher início, fim e intervalo
usar atalhos de 12h e 24h
adicionar um horário avulso
cancelar horários pending
encerrar e sortear agora em emergência
```

A mesma rodada serve aos dois jogos.

# Administração

O painel mostra:

```text
rodada atual
estado OPEN/LOCKED
contagem regressiva
último Número Lendário
última Dupla Lendária
totais apostados em cada número 0..10
totais apostados nas 45 combinações da Dupla Lendária
apostas recentes dos dois jogos
depósitos pendentes
saques pendentes
jogadores e saldos
```

Na Dupla Lendária o painel mostra sempre a combinação normalizada:

```text
1+9
```

e nunca cria outra linha separada para `9+1`.

# Consultas úteis

## Total por número — Número Lendário

```sql
select
  selected_number,
  count(*) as quantidade_de_apostas,
  sum(amount) as total_apostado
from public.bets
group by selected_number
order by selected_number;
```

## Total por combinação — Dupla Lendária

```sql
select
  number_a,
  number_b,
  count(*) as quantidade_de_apostas,
  sum(amount) as total_apostado
from public.pair_bets
group by number_a, number_b
order by number_a, number_b;
```

## Apostas individuais do Número Lendário

```sql
select
  r.round_no,
  b.selected_number,
  b.amount,
  b.player_id,
  b.created_at
from public.bets b
join public.game_rounds r on r.id = b.round_id
order by b.created_at desc;
```

## Apostas individuais da Dupla Lendária

```sql
select
  r.round_no,
  pb.number_a,
  pb.number_b,
  pb.amount,
  pb.player_id,
  pb.created_at
from public.pair_bets pb
join public.game_rounds r on r.id = pb.round_id
order by pb.created_at desc;
```

## Ver rodadas e os dois resultados

```sql
select
  round_no,
  status,
  opened_at,
  closes_at,
  draw_at,
  drawn_number,
  pair_drawn_a,
  pair_drawn_b,
  drawn_at,
  published_at
from public.game_rounds
order by round_no desc;
```

## Ver Cron

```sql
select jobid, jobname, schedule, command, active
from cron.job
order by jobid;
```

## Ver programação

```sql
select id, draw_at, status, round_id, created_at
from public.draw_schedule
order by draw_at;
```

# Principais tabelas

```text
players
player_sessions
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

# Principais funções

```text
jl_place_bet(...)
    aposta no Número Lendário

jl_place_pair_bet(...)
    aposta na Dupla Lendária

jl_secure_number()
    resultado do Número Lendário

jl_secure_pair(round_id)
    resultado uniforme entre as 45 combinações da Dupla Lendária

jl_finalize_due_rounds()
    calcula resultados, vencedores e pagamentos dos dois jogos

jl_process_game_engine()
    controla OPEN → LOCKED → sorteio → próxima rodada

jl_public_state()
    estado público e últimos resultados

jl_player_state(...)
    conta e histórico do jogador nos dois jogos

jl_admin_dashboard(...)
    dados administrativos dos dois jogos

jl_admin_open_round(...)
    abre rodada manual

jl_admin_schedule_draws(...)
    cria vários horários

jl_admin_add_draw_time(...)
    adiciona horário avulso

jl_admin_cancel_draw_time(...)
    cancela horário pending

jl_admin_clear_draw_schedule(...)
    cancela horários pending
```

# Depósitos

Fluxo:

```text
jogador transfere
      ↓
solicita depósito e informa referência
      ↓
pending
      ↓
admin aprova ou rejeita
      ↓
aprovado → saldo aumenta
```

Nesta fase não existe transferência automática real por M-Pesa ou banco.

# Saques

Saldo insuficiente:

```text
pedido → rejeição automática
```

Saldo suficiente:

```text
valor reservado
      ↓
pending
      ↓
admin aprova ou rejeita
      ↓
aprovado = débito permanece
rejeitado = valor retorna ao saldo
```

# Como clonar e testar localmente

Primeira vez:

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
git status
git switch main
git pull origin main
python3 -m http.server 8080
```

# Fluxo de cada retificação

Sempre seguir:

```text
1. atualizar a branch main
2. alterar somente o necessário
3. se houver mudança de banco, criar migration
4. testar localmente
5. verificar git status e git diff
6. commit claro
7. push origin main
8. Cloudflare detecta o push
9. deploy automático
10. testar produção
11. se houver migration, confirmar também o Supabase
12. testar o fluxo completo afetado
```

Comandos:

```bash
git switch main
git pull origin main

# editar e testar

git status
git diff
git add .
git commit -m "Descrição clara da retificação"
git push origin main
```

# Produção

Configuração:

```text
GitHub:     Progaminy/jogos-lendarios
Branch:     main
Cloudflare: Worker jogos-lendarios
Domínio:    jogoslendarios.adadpsf.shop
Supabase:   bxndjyzghgrmkelshtdp
```

Fluxo normal:

```text
push main
   ↓
Cloudflare detecta
   ↓
build/deploy
   ↓
produção atualizada
```

Não fazer upload manual de cada retificação no Cloudflare.

Confirmar em:

```text
Cloudflare
→ Workers e Pages
→ jogos-lendarios
→ Implantações
```

Testar:

```text
https://jogoslendarios.adadpsf.shop
https://jogoslendarios.adadpsf.shop/admin.html
```

# Retificações no Supabase

Mudanças de estrutura ou regra devem virar migration versionada em:

```text
supabase/migrations/
```

Exemplos:

```text
nova tabela
nova coluna
nova RPC
mudança de pagamento
mudança de regra do sorteio
novo índice
mudança de Cron
```

A migration da Dupla Lendária é:

```text
supabase/migrations/20260916_add_dupla_lendaria_game.sql
```

# Segurança

`config.js` pode conter somente informações públicas necessárias ao navegador:

```text
URL pública do Supabase
publishable key
```

Nunca colocar no GitHub:

```text
service_role
senha do banco
chaves privadas
tokens administrativos
segredos de infraestrutura
```

Funções internas como:

```text
jl_secure_number()
jl_secure_pair(uuid)
jl_finalize_due_rounds()
jl_process_game_engine()
jl_open_next_scheduled_round()
```

não devem depender do navegador para proteger a lógica real.

# Rollback

Frontend:

```bash
git log --oneline
git revert <SHA_DO_COMMIT>
git push origin main
```

Banco: criar uma nova migration corretiva compatível. Não apagar dados de produção sem verificar dependências.

# Checklist de retificação

```text
[ ] main atualizada
[ ] alteração testada localmente
[ ] migration criada quando necessário
[ ] git diff conferido
[ ] nenhum segredo incluído
[ ] commit claro
[ ] push concluído
[ ] Cloudflare implantou
[ ] produção testada
[ ] Número Lendário testado quando afetado
[ ] Dupla Lendária testada quando afetada
[ ] admin testado quando aplicável
[ ] Supabase testado quando aplicável
[ ] fluxo afetado testado de ponta a ponta
```

# Regra central atual

```text
ADMIN define um ou vários horários
        ↓
SUPABASE programa
        ↓
RODADA OPEN
        ↓
JOGADORES podem apostar em um ou nos dois jogos
        ↓
3 segundos antes
        ↓
RODADA LOCKED
        ↓
nenhuma nova aposta é aceite
        ↓
HORA exata
        ↓
NÚMERO LENDÁRIO
calcula totais 0..10
        ↓
encontra o menor total
        ↓
sorteia entre os empatados no menor total
        ↓
paga 10× aos vencedores

E, NA MESMA RODADA:

DUPLA LENDÁRIA
gera uma das 45 combinações uniformemente
        ↓
ordem canónica a < b
        ↓
paga 50× aos vencedores
        ↓
SISTEMA publica os dois resultados
        ↓
SISTEMA abre a próxima rodada programada
```

**Regra fundamental da Dupla Lendária:** `1+9` e `9+1` são a mesma combinação. O banco normaliza a ordem e guarda sempre o menor número primeiro.

**Regra fundamental da documentação:** o README deve refletir exatamente a lógica que está ativa no Supabase e no frontend.

# Jogos Lendários

Projeto do jogo **Número Lendário**, com frontend no GitHub, dados e lógica sensível no Supabase e publicação em produção no Cloudflare Workers.

## Arquitetura atual

```text
GitHub — branch main
        │
        │ fonte oficial do frontend e configuração versionada
        ▼
Cloudflare Workers + Static Assets
        │
        ▼
https://jogoslendarios.adadpsf.shop

Supabase
        │
        ├── jogadores e sessões
        ├── saldos
        ├── apostas
        ├── depósitos e saques
        ├── rodadas
        ├── programação de sorteios
        ├── transações
        ├── auditoria
        └── lógica real do jogo
```

A branch `main` do GitHub é a fonte oficial do frontend. O Supabase é a fonte oficial dos dados e da lógica do banco. Não manter cópias diferentes do site editadas manualmente no Cloudflare.

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

# Estrutura do projeto

```text
jogos-lendarios/
├── index.html
├── styles.css
├── config.js
├── app.js
├── admin.html
├── admin.js
├── wrangler.jsonc
├── .assetsignore
├── .gitignore
├── .nojekyll
├── supabase/
│   └── migrations/
│       ├── 20260916_scheduled_rounds_with_three_second_lock.sql
│       └── 20260916_add_locked_round_state.sql
└── README.md
```

Não existe backend Node separado. O frontend é HTML/CSS/JavaScript estático. A lógica sensível fica no Supabase/PostgreSQL.

# Fluxo do jogador

1. escolhe um número de `0` a `10`;
2. informa o valor da aposta;
3. clica em **Apostar**;
4. se ainda não estiver autenticado, abre **Criar conta / Já tenho conta**;
5. depois do cadastro/login, a aposta pendente continua automaticamente;
6. o Supabase valida rodada, horário e saldo;
7. desconta o valor do saldo;
8. grava a aposta em `public.bets`;
9. **3 segundos antes do sorteio** novas apostas são bloqueadas;
10. na hora marcada o Supabase executa o sorteio;
11. identifica vencedores, calcula prémios e credita saldos;
12. publica o resultado;
13. se existir outro horário programado, abre automaticamente a rodada seguinte.

Quem ganha recebe **10× o valor apostado**.

# Bloqueio de 3 segundos antes do sorteio

Cada rodada possui dois horários:

```text
closes_at = momento em que novas apostas são bloqueadas
draw_at   = momento em que o sorteio é executado
```

A diferença é:

```text
draw_at - closes_at = 3 segundos
```

Exemplo:

```text
Sorteio: 14:00:00
Bloqueio: 13:59:57
```

O estado da rodada passa por:

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

Durante `LOCKED`, o jogador já não consegue apostar. A proteção real está no banco: `jl_place_bet(...)` exige `status = 'open'` e `closes_at > now()`.

# Administração flexível

O administrador pode abrir uma rodada manual ou programar várias de uma vez.

## Rodada manual

Escolhe a hora exata do sorteio e clica em **Abrir jogo**.

O banco cria:

```text
draw_at   = hora escolhida
closes_at = draw_at - 3 segundos
status    = open
```

## Programar um período

O painel aceita:

```text
primeiro sorteio
último sorteio
intervalo em minutos
```

Exemplo:

```text
Início:    12:00
Fim:       15:00
Intervalo: 60 minutos
```

Cria:

```text
12:00
13:00
14:00
15:00
```

O painel também oferece atalhos para períodos de **12 horas** e **24 horas**.

O intervalo pode ser ajustado, por exemplo:

```text
15 min
30 min
60 min
120 min
```

Cada lote pode criar até 250 horários e pode cobrir os próximos 7 dias.

## Horário avulso

Também é possível adicionar apenas um horário futuro sem recriar a programação inteira.

## Cancelamento

Horários com estado `pending` podem ser cancelados individualmente ou todos de uma vez.

A rodada já ativa não é cancelada por esse botão. Para ela existe **Encerrar e sortear agora**.

# Tabela de programação

```text
public.draw_schedule
```

Campos principais:

```text
id         identificador
draw_at    hora do sorteio
status     pending | active | completed | cancelled | missed
round_id   rodada ligada ao horário
created_at criação
updated_at atualização
```

Estados:

```text
pending   → aguardando
active    → horário transformado em rodada atual
completed → sorteio concluído
cancelled → cancelado pelo admin
missed    → horário passou sem ser ativado
```

# Motor automático

A função central é:

```text
jl_process_game_engine()
```

O Supabase Cron executa o job:

```text
jogos_lendarios_engine
```

com intervalo:

```text
1 second
```

O motor é serializado com `pg_try_advisory_xact_lock(...)` para evitar que duas requisições simultâneas abram duas rodadas.

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
sorteio
      ↓
pagamentos
      ↓
status = PUBLISHED
      ↓
schedule = completed
      ↓
jl_open_next_scheduled_round()
      ↓
próxima rodada OPEN
```

`jl_public_state()` e `jl_admin_dashboard()` também chamam o motor, portanto as consultas ao site ajudam a processar transições pendentes além do Cron.

# Funções principais

```text
jl_admin_open_round(...)
    abre uma rodada manual

jl_admin_schedule_draws(...)
    cria vários horários entre início e fim

jl_admin_add_draw_time(...)
    adiciona um horário avulso

jl_admin_cancel_draw_time(...)
    cancela um horário pending

jl_admin_clear_draw_schedule(...)
    cancela horários pending

jl_open_next_scheduled_round()
    abre a próxima rodada programada

jl_process_game_engine()
    controla OPEN → LOCKED → sorteio → próxima rodada

jl_place_bet(...)
    valida e grava apostas

jl_finalize_due_rounds()
    finaliza a rodada e paga vencedores

jl_secure_number()
    determina o número vencedor

jl_public_state()
    estado público

jl_admin_dashboard(...)
    estado administrativo
```

# Lógica atual do número vencedor

A lógica real fica em:

```text
public.jl_secure_number()
```

Para ver o código:

```sql
select pg_get_functiondef(
  'public.jl_secure_number()'::regprocedure
);
```

## Regra atual

A função **não sorteia diretamente entre todos os números de 0 a 10**.

Primeiro ela calcula o total apostado em cada número da rodada ativa:

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

O menor total é `100 MZN`, então os candidatos seriam:

```text
1 e 2
```

A função usa `extensions.gen_random_bytes(1)` para escolher aleatoriamente **entre os candidatos empatados com o menor total apostado**.

Ela usa rejeição antes do módulo para evitar favorecer uma posição da lista quando a quantidade de candidatos não divide 256 exatamente.

Fluxo atual:

```text
pegar rodada OPEN ou LOCKED
      ↓
calcular SUM(amount) para 0..10
      ↓
encontrar menor total
      ↓
montar lista dos números com esse menor total
      ↓
gerar byte criptográfico
      ↓
escolher uniformemente entre os candidatos
      ↓
retornar número vencedor
```

**Portanto, na lógica atual, os valores apostados influenciam quais números entram na lista de candidatos do sorteio.**

Isso deve ser mantido documentado para que a regra real do banco e o README nunca entrem em contradição.

# Como as apostas são guardadas

Cada aposta é uma linha individual em:

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

Exemplo:

```text
Jogador A → número 0 → 100 MZN
Jogador B → número 0 →  50 MZN
Jogador C → número 7 →  20 MZN
```

São três linhas diferentes.

O total do `0` é calculado:

```text
100 + 50 = 150 MZN
```

# Função que grava a aposta

```text
jl_place_bet(text, integer, numeric)
```

Para ver:

```sql
select pg_get_functiondef(
  'public.jl_place_bet(text,integer,numeric)'::regprocedure
);
```

Ela valida:

```text
número entre 0 e 10
valor válido
rodada open
closes_at ainda no futuro
jogador autenticado
jogador não bloqueado
saldo suficiente
```

Depois desconta:

```sql
update public.players
set
  balance = balance - p_amount,
  updated_at = now()
where id = v_player_id;
```

E grava:

```sql
insert into public.bets(
  round_id,
  player_id,
  selected_number,
  amount
)
values(
  v_round.id,
  v_player_id,
  p_selected_number,
  round(p_amount, 2)
)
returning id into v_bet_id;
```

Também registra a saída em `public.transactions` com `kind = 'bet'`.

# Como ver o total apostado por número

```sql
select
  selected_number,
  count(*) as quantidade_de_apostas,
  sum(amount) as total_apostado
from public.bets
group by selected_number
order by selected_number;
```

Para a rodada atual com todos os números de `0` a `10`, inclusive os que têm zero:

```sql
with rodada_atual as (
  select id
  from public.game_rounds
  where status = 'open'
    and closes_at > now()
  order by opened_at desc
  limit 1
)
select
  n as numero,
  count(b.id) as quantidade_de_apostas,
  coalesce(sum(b.amount), 0) as total_apostado
from generate_series(0, 10) as n
left join rodada_atual r on true
left join public.bets b
  on b.round_id = r.id
 and b.selected_number = n
group by n
order by n;
```

O painel administrativo usa a mesma ideia dentro de `jl_admin_dashboard(...)`.

# Ver apostas individuais

```sql
select
  r.round_no,
  b.selected_number,
  b.amount,
  b.player_id,
  b.created_at
from public.bets b
join public.game_rounds r
  on r.id = b.round_id
order by b.created_at desc;
```

# Finalização e pagamento

Para ver a função:

```sql
select pg_get_functiondef(
  'public.jl_finalize_due_rounds()'::regprocedure
);
```

Ela processa rodadas quando:

```sql
draw_at <= now()
```

Fluxo:

```text
jl_secure_number()
      ↓
grava drawn_number
      ↓
won = selected_number == drawn_number
      ↓
payout = amount × 10 para vencedores
      ↓
credita saldo
      ↓
registra transaction payout
      ↓
registra audit_log
      ↓
marca schedule completed
      ↓
publica rodada
```

# Administração

O administrador pode:

- abrir rodada manual;
- programar vários sorteios;
- definir início, fim e intervalo;
- usar atalhos de 12h e 24h;
- adicionar horário avulso;
- cancelar horários futuros;
- acompanhar OPEN / LOCKED / sorteio;
- encerrar e sortear agora em emergência;
- ver quantidade de apostas por número;
- ver total apostado por número;
- ver apostas recentes;
- ver último resultado;
- aprovar/rejeitar depósitos;
- autorizar/rejeitar saques;
- ajustar saldo;
- bloquear/desbloquear jogador.

# Depósitos

```text
jogador solicita
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

# Principais tabelas

```text
players
player_sessions
game_rounds
draw_schedule
bets
deposit_requests
withdrawal_requests
transactions
admin_sessions
admin_config
audit_log
```

# Como clonar

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
```

# Fluxo de cada retificação

```text
1. atualizar main
2. alterar somente o necessário
3. testar localmente
4. git status / git diff
5. commit claro
6. push origin main
7. Cloudflare detecta
8. deploy automático
9. testar produção
10. se envolver banco, testar também Supabase
```

Comandos:

```bash
git switch main
git pull origin main

# editar/testar

git status
git diff
git add .
git commit -m "Descrição clara da retificação"
git push origin main
```

# Produção

Configuração já existente:

```text
GitHub:     Progaminy/jogos-lendarios
Branch:     main
Cloudflare: Worker jogos-lendarios
Domínio:    jogoslendarios.adadpsf.shop
Supabase:   bxndjyzghgrmkelshtdp
```

Depois da configuração inicial, não fazer upload manual de cada alteração.

```text
push main
   ↓
Cloudflare detecta
   ↓
build/deploy
   ↓
produção atualizada
```

Confirmar em:

```text
Cloudflare
→ Workers e Pages
→ jogos-lendarios
→ Implantações
```

Testar sempre:

```text
https://jogoslendarios.adadpsf.shop
https://jogoslendarios.adadpsf.shop/admin.html
```

# Retificações no Supabase

Mudanças de estrutura ou lógica devem virar migration.

Exemplos:

```text
nova tabela
nova coluna
nova RPC
mudança de regra
novo índice
mudança de Cron
```

As migrations relacionadas à programação atual estão versionadas em:

```text
supabase/migrations/
```

# Consultas úteis

Ver função do número vencedor:

```sql
select pg_get_functiondef(
  'public.jl_secure_number()'::regprocedure
);
```

Ver motor:

```sql
select pg_get_functiondef(
  'public.jl_process_game_engine()'::regprocedure
);
```

Ver próxima rodada:

```sql
select pg_get_functiondef(
  'public.jl_open_next_scheduled_round()'::regprocedure
);
```

Ver Cron:

```sql
select jobid, jobname, schedule, command, active
from cron.job
order by jobid;
```

Ver programação:

```sql
select id, draw_at, status, round_id, created_at
from public.draw_schedule
order by draw_at;
```

Ver rodadas:

```sql
select
  round_no,
  status,
  opened_at,
  closes_at,
  draw_at,
  drawn_number,
  drawn_at,
  published_at
from public.game_rounds
order by round_no desc;
```

# Segurança

`config.js` deve conter somente dados públicos necessários ao navegador:

- URL pública do Supabase;
- publishable key.

Nunca colocar no GitHub:

- `service_role`;
- senha do banco;
- chaves privadas;
- tokens administrativos;
- segredos de infraestrutura.

Funções internas como `jl_secure_number()`, `jl_finalize_due_rounds()`, `jl_process_game_engine()` e `jl_open_next_scheduled_round()` não precisam ser chamadas diretamente pelo navegador.

# Rollback

Frontend:

```bash
git log --oneline
git revert <SHA_DO_COMMIT>
git push origin main
```

Banco: corrigir com uma nova migration compatível. Não apagar dados de produção sem verificar dependências.

# Checklist de retificação

- main atualizada;
- alteração testada;
- `git diff` conferido;
- nenhum segredo incluído;
- commit claro;
- push concluído;
- Cloudflare implantou;
- produção testada;
- admin testado quando aplicável;
- Supabase testado quando aplicável;
- fluxo afetado testado de ponta a ponta.

# Regra central atual

```text
ADMIN define um ou vários horários
        ↓
SUPABASE programa
        ↓
RODADA OPEN
        ↓
JOGADORES apostam
        ↓
3 segundos antes
        ↓
RODADA LOCKED
        ↓
HORA exata
        ↓
SISTEMA calcula os totais apostados por número
        ↓
SISTEMA encontra o menor total
        ↓
SISTEMA sorteia entre os números empatados nesse menor total
        ↓
SISTEMA calcula vencedores
        ↓
SISTEMA paga 10×
        ↓
SISTEMA publica resultado
        ↓
SISTEMA abre próxima rodada programada
```

**O administrador pode programar várias horas de uma vez; as apostas bloqueiam 3 segundos antes de cada sorteio; e o README deve sempre refletir exatamente a lógica que está realmente ativa no Supabase.**

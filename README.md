# Jogos Lendários

Projeto do jogo **Número Lendário**, com frontend no GitHub, dados e lógica sensível no Supabase e publicação de produção no Cloudflare Workers.

## Arquitetura atual

```text
GitHub — branch main
        │
        │ fonte oficial do frontend e da configuração versionada
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
        └── lógica real do sorteio
```

A branch `main` do GitHub é a fonte oficial do frontend. O Supabase é a fonte oficial dos dados e da lógica do banco. Não manter cópias diferentes do site editadas manualmente no Cloudflare.

## Endereços

Produção principal:

```text
https://jogoslendarios.adadpsf.shop
```

Administração:

```text
https://jogoslendarios.adadpsf.shop/admin.html
```

URL técnica do Worker:

```text
https://jogos-lendarios.pensadorsemfronteiras0.workers.dev
```

# Estrutura do frontend

```text
jogos-lendarios/
├── index.html        # interface do jogador
├── styles.css        # aparência
├── config.js         # URL e publishable key do Supabase
├── app.js            # interação do jogador e chamadas RPC
├── admin.html        # painel administrativo
├── admin.js          # chamadas administrativas
├── wrangler.jsonc    # configuração do Cloudflare Worker
├── .assetsignore
├── .gitignore
├── .nojekyll
└── README.md
```

Não existe backend Node separado. O frontend é HTML/CSS/JavaScript estático. A lógica sensível fica no Supabase/PostgreSQL.

# Fluxo do jogador

1. escolhe um número de `0` a `10`;
2. informa o valor da aposta;
3. clica em **Apostar**;
4. se ainda não estiver autenticado, abre **Criar conta / Já tenho conta**;
5. o cadastro usa nome, telefone, PIN e confirmação do PIN;
6. depois do cadastro/login, a aposta pendente continua automaticamente;
7. o Supabase valida rodada, horário e saldo;
8. o valor é descontado do saldo;
9. a aposta é gravada em `public.bets`;
10. **3 segundos antes do sorteio** novas apostas são bloqueadas;
11. na hora marcada o Supabase sorteia automaticamente um número;
12. identifica vencedores, calcula os prémios e credita os saldos;
13. publica o resultado;
14. se houver outro horário programado, a rodada seguinte é aberta automaticamente.

Quem acerta recebe **10× o valor apostado**.

# Regra dos 3 segundos antes do sorteio

A partir da programação atual, existem dois horários diferentes em cada rodada:

```text
closes_at = momento em que novas apostas são bloqueadas
draw_at   = momento em que o número é sorteado
```

A diferença é fixa:

```text
draw_at - closes_at = 3 segundos
```

Exemplo:

```text
Sorteio programado: 14:00:00
Bloqueio de apostas: 13:59:57
Sorteio:             14:00:00
```

Fluxo:

```text
APOSTAS ABERTAS
      ↓
13:59:57
      ↓
APOSTAS BLOQUEADAS
      ↓
3 segundos
      ↓
14:00:00
      ↓
SORTEIO AUTOMÁTICO
      ↓
PAGAMENTO / PUBLICAÇÃO
      ↓
PRÓXIMA RODADA, se programada
```

O frontend mostra visualmente esse estado, mas a regra verdadeira fica no banco. Mesmo que alguém tente chamar a API diretamente, `jl_place_bet(...)` só aceita aposta se a rodada estiver `open` e `closes_at > now()`.

# Administração flexível e programação de vários sorteios

O administrador não precisa abrir uma rodada de cada vez.

O painel permite duas formas principais.

## 1. Abrir uma rodada manual

O administrador escolhe uma data/hora de sorteio e clica em **Abrir jogo**.

O banco cria:

```text
draw_at   = hora escolhida
closes_at = draw_at - 3 segundos
status    = open
```

## 2. Programar um período inteiro

O administrador pode informar:

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

O sistema programa:

```text
12:00
13:00
14:00
15:00
```

Também existem atalhos no painel para preparar períodos de **12 horas** e **24 horas**.

O intervalo é flexível. Pode ser, por exemplo:

```text
15 minutos
30 minutos
60 minutos
120 minutos
```

O banco limita cada lote a 250 horários e aceita programação dentro dos próximos 7 dias.

## 3. Adicionar um horário avulso

O administrador também pode adicionar apenas um horário futuro sem recriar toda a programação.

## 4. Cancelar programação futura

Horários ainda com estado `pending` podem ser cancelados individualmente ou todos de uma vez.

Uma rodada já ativa não é cancelada por esse botão; para ela existe a ação administrativa de emergência **Encerrar e sortear agora**.

# Como a programação automática funciona no banco

A tabela responsável pelos horários é:

```text
public.draw_schedule
```

Principais campos:

```text
id         identificador do horário
draw_at    hora exata do sorteio
status     pending | active | completed | cancelled | missed
round_id   rodada ligada ao horário
created_at criação
updated_at última atualização
```

Estados:

```text
pending   → horário futuro aguardando
active    → horário já virou a rodada atual
completed → sorteio executado
cancelled → cancelado pelo administrador
missed    → horário passou sem possibilidade de abrir rodada
```

A rodada ativa possui também:

```text
public.game_rounds.draw_at
public.game_rounds.closes_at
public.game_rounds.schedule_id
```

# Motor automático do jogo

O motor principal é:

```text
jl_process_game_engine()
```

Ele é executado pelo Supabase Cron em intervalo de **1 segundo**.

O job atual é:

```text
jogos_lendarios_engine
```

Fluxo do motor:

```text
verificar rodada aberta
        ↓
closes_at chegou?
        ↓ sim
mudar para CLOSED / bloquear apostas
        ↓
draw_at chegou?
        ↓ sim
jl_finalize_due_rounds()
        ↓
sortear e publicar
        ↓
marcar horário como completed
        ↓
jl_open_next_scheduled_round()
        ↓
abrir próximo horário pending
```

Além do Cron, `jl_public_state()` e `jl_admin_dashboard()` também chamam o motor. Isso dá redundância operacional: quando o site ou o painel consulta o estado, o banco também confere se existe alguma transição pendente.

O Supabase Cron suporta agendamentos sub-minuto, incluindo intervalos de 1 a 59 segundos.

# Funções principais do Supabase

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
    cancela todos os horários pending

jl_open_next_scheduled_round()
    transforma o próximo horário pending em rodada open

jl_process_game_engine()
    controla bloqueio, sorteio e abertura da próxima rodada

jl_place_bet(...)
    valida e grava aposta

jl_finalize_due_rounds()
    executa o sorteio e pagamentos quando draw_at chega

jl_secure_number()
    gera o número vencedor 0..10

jl_public_state()
    devolve o estado público do jogo

jl_admin_dashboard(...)
    devolve estado, programação, apostas, saldos e pedidos ao admin
```

# Onde está a lógica do sorteio

A função que gera o número é:

```text
public.jl_secure_number()
```

Para ver o código no SQL Editor:

```sql
select pg_get_functiondef(
  'public.jl_secure_number()'::regprocedure
);
```

A lógica é equivalente a:

```sql
loop
  b := get_byte(extensions.gen_random_bytes(1), 0);
  if b < 253 then
    return b % 11;
  end if;
end loop;
```

Funcionamento:

```text
1. gera um byte aleatório entre 0 e 255
2. aceita apenas 0..252
3. 253, 254 e 255 são rejeitados e gerados novamente
4. calcula valor % 11
5. resultado final fica entre 0 e 10
```

Como `253 = 23 × 11`, cada número recebe a mesma quantidade de possibilidades na transformação aceita.

**O total apostado em cada número não entra no cálculo do número vencedor.**

# Finalização da rodada

Para ver a função completa:

```sql
select pg_get_functiondef(
  'public.jl_finalize_due_rounds()'::regprocedure
);
```

Hoje ela finaliza rodadas quando:

```sql
draw_at <= now()
```

Ela:

```text
fecha a rodada se ainda estiver open
      ↓
gera o número com jl_secure_number()
      ↓
grava drawn_number
      ↓
marca apostas vencedoras
      ↓
payout = amount × 10
      ↓
credita saldos
      ↓
registra transações de payout
      ↓
registra auditoria
      ↓
marca schedule como completed
      ↓
publica a rodada
```

# Como as apostas e os valores são guardados

O sistema não guarda apenas um total por número. **Cada aposta é uma linha individual** em:

```text
public.bets
```

Principais colunas:

```text
id               identificador da aposta
round_id         rodada
player_id        jogador
selected_number  número escolhido 0..10
amount           valor apostado
won              resultado da aposta
payout           prémio
created_at       data/hora
```

Exemplo:

```text
Jogador A → número 0 → 100 MZN
Jogador B → número 0 →  50 MZN
Jogador C → número 7 →  20 MZN
```

O banco guarda três linhas.

Para o número `0`, o total é calculado:

```text
100 + 50 = 150 MZN
```

# Função que grava a aposta

A função é:

```text
jl_place_bet(text, integer, numeric)
```

Para vê-la:

```sql
select pg_get_functiondef(
  'public.jl_place_bet(text,integer,numeric)'::regprocedure
);
```

Ela recebe:

```text
p_token            sessão
p_selected_number  número
p_amount            valor
```

Valida:

```text
número 0..10
valor válido
rodada open
closes_at ainda não alcançado
jogador autenticado
jogador não bloqueado
saldo suficiente
```

Depois desconta o saldo:

```sql
update public.players
set
  balance = balance - p_amount,
  updated_at = now()
where id = v_player_id;
```

E grava a aposta:

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

Também grava a movimentação em `public.transactions` com `kind = 'bet'` e valor negativo.

# Como o total de cada número é calculado

Consulta básica:

```sql
select
  selected_number,
  count(*) as quantidade_de_apostas,
  sum(amount) as total_apostado
from public.bets
group by selected_number
order by selected_number;
```

A função `jl_admin_dashboard(...)` calcula esses valores para a rodada atual e combina com `generate_series(0,10)`, por isso o admin também vê os números que ainda têm zero apostas.

Exemplo:

```text
Número 0  → 3 apostas → 170 MZN
Número 1  → 0 apostas →   0 MZN
Número 2  → 5 apostas → 420 MZN
...
Número 10 → 2 apostas →  80 MZN
```

## Ver totais da rodada aberta

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

## Ver apostas individuais

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

# Independência entre dinheiro apostado e sorteio

Os totais são apenas informação administrativa.

```text
total no número 0 → não influencia jl_secure_number()
total no número 7 → não influencia jl_secure_number()
```

O sorteio não procura o número mais barato, mais caro, mais apostado ou menos apostado.

# Administração

O painel administrativo pode:

- abrir uma rodada manual;
- programar vários sorteios de uma vez;
- definir início, fim e intervalo;
- usar atalhos de 12h e 24h;
- adicionar horário avulso;
- cancelar horários futuros;
- acompanhar rodada e contagem;
- ver o bloqueio de 3 segundos;
- encerrar e sortear agora em emergência;
- ver quantidade de apostas por número;
- ver total apostado por número;
- ver apostas recentes;
- ver último resultado;
- aprovar/rejeitar depósitos;
- autorizar/rejeitar saques;
- ajustar saldo;
- bloquear/desbloquear jogador.

Não existe uma ação normal para escolher manualmente o número vencedor.

# Depósitos

```text
jogador solicita depósito
        ↓
pedido pending
        ↓
admin aprova ou rejeita
        ↓
aprovado → saldo aumenta
```

Nesta fase não existe transferência automática real por M-Pesa ou banco.

# Saques

Saldo insuficiente:

```text
pedido
  ↓
rejeição automática
```

Saldo suficiente:

```text
valor reservado
      ↓
pedido pending
      ↓
admin aprova ou rejeita
      ↓
aprovado = débito permanece
rejeitado = valor volta ao saldo
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

# Como clonar e rodar localmente

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
```

# Fluxo obrigatório de cada retificação

```text
1. atualizar main
2. fazer alteração
3. testar localmente
4. git status / git diff
5. commit claro
6. push origin main
7. Cloudflare detecta o commit
8. Cloudflare faz deploy
9. testar produção
10. se envolver banco, confirmar também Supabase
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

# Como colocar online e em produção

A primeira configuração já está feita:

```text
GitHub:     Progaminy/jogos-lendarios
Branch:     main
Cloudflare: Worker jogos-lendarios
Assets:     raiz do repositório
Domínio:    jogoslendarios.adadpsf.shop
Supabase:   bxndjyzghgrmkelshtdp
```

Depois disso não é necessário fazer upload manual no Cloudflare.

```text
commit/push para main
        ↓
Cloudflare detecta
        ↓
build/deploy automático
        ↓
produção atualizada
```

Confirmar deploy em:

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

Mudanças estruturais de banco devem ser feitas como migration.

Exemplos:

```text
nova tabela
nova coluna
nova função RPC
alteração da lógica do jogo
novo índice
mudança do Cron
```

Depois de uma migration:

```text
1. validar funções
2. validar tabelas
3. validar Cron
4. testar fluxo do jogador
5. testar painel admin
6. atualizar README/código correspondente
7. push main
8. testar produção completa
```

# Consultas úteis para auditoria

Ver motor:

```sql
select pg_get_functiondef(
  'public.jl_process_game_engine()'::regprocedure
);
```

Ver abertura automática da próxima rodada:

```sql
select pg_get_functiondef(
  'public.jl_open_next_scheduled_round()'::regprocedure
);
```

Ver função que programa vários horários:

```sql
select pg_get_functiondef(
  'public.jl_admin_schedule_draws(text,timestamp with time zone,timestamp with time zone,integer)'::regprocedure
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

`config.js` pode conter apenas dados públicos necessários ao navegador:

- URL pública do Supabase;
- publishable key.

Nunca colocar no GitHub:

- `service_role`;
- senha do banco;
- chaves privadas;
- tokens administrativos;
- segredos de infraestrutura.

# Rollback de frontend

Se um commit causar problema:

```bash
git log --oneline
git revert <SHA_DO_COMMIT>
git push origin main
```

O Cloudflare publica o revert como uma nova versão.

Rollback de banco deve ser feito com uma migration de correção compatível. Não apagar dados de produção sem verificar dependências.

# Checklist antes de considerar uma retificação concluída

- `main` atualizada;
- alteração feita apenas onde necessário;
- teste local realizado;
- `git diff` conferido;
- nenhum segredo adicionado ao repositório;
- commit claro;
- push concluído;
- build do Cloudflare concluído;
- domínio de produção testado;
- painel admin testado quando aplicável;
- Supabase testado quando aplicável;
- fluxo principal afetado testado do início ao fim.

# Regra central

```text
ADMIN define um ou vários horários
        ↓
SUPABASE cria a programação
        ↓
RODADA abre
        ↓
JOGADORES apostam
        ↓
3 segundos antes
        ↓
APOSTAS são bloqueadas
        ↓
HORA exata chega
        ↓
SISTEMA sorteia automaticamente
        ↓
SISTEMA calcula vencedores
        ↓
SISTEMA paga vencedores
        ↓
SISTEMA publica resultado
        ↓
SISTEMA abre a próxima rodada programada
```

**A programação pode cobrir várias horas de uma vez, o bloqueio ocorre 3 segundos antes do sorteio e o número vencedor continua sendo gerado independentemente dos valores apostados em cada número.**

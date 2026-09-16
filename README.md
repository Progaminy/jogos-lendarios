# Jogos Lendários

Projeto do jogo **Número Lendário**, com frontend no GitHub, lógica sensível e dados no Supabase e publicação de produção no Cloudflare Workers.

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

## Estrutura do frontend

```text
jogos-lendarios/
├── index.html        # interface do jogador
├── styles.css        # aparência
├── config.js         # URL e publishable key do Supabase
├── app.js            # interação do jogador e chamadas RPC
├── admin.html        # interface administrativa
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
5. cadastro usa nome, telefone, PIN e confirmação do PIN;
6. depois do cadastro/login, a aposta pendente continua automaticamente;
7. o Supabase valida rodada e saldo;
8. o valor é descontado do saldo;
9. a aposta é gravada na tabela `bets`;
10. quando chega a hora definida pelo administrador, a rodada fecha;
11. o Supabase sorteia automaticamente um número;
12. identifica vencedores, calcula os prémios e credita os saldos;
13. publica o resultado.

Quem acerta recebe **10× o valor apostado**.

Se não existir rodada aberta ou se o horário já tiver terminado, o botão **Apostar** fica desativado e o banco também recusa novas apostas.

# Onde está a lógica do sorteio

A lógica real do sorteio fica no Supabase, principalmente nestas funções:

```text
jl_admin_open_round(...)
jl_place_bet(...)
jl_finalize_due_rounds()
jl_secure_number()
jl_public_state()
jl_admin_dashboard(...)
```

Fluxo principal:

```text
ADMIN define a hora
        ↓
jl_admin_open_round(...)
        ↓
game_rounds.closes_at
        ↓
JOGADORES apostam
        ↓
jl_place_bet(...)
        ↓
HORA chega
        ↓
jl_finalize_due_rounds()
        ↓
jl_secure_number()
        ↓
número vencedor 0..10
        ↓
marca vencedores
        ↓
calcula 10×
        ↓
atualiza saldos
        ↓
registra transações
        ↓
publica resultado
```

## `jl_secure_number()`

É a função que gera o número vencedor.

Para visualizar o código diretamente no Supabase SQL Editor:

```sql
select pg_get_functiondef(
  'public.jl_secure_number()'::regprocedure
);
```

A lógica atual é equivalente a:

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

Como `253 = 23 × 11`, cada número de `0` a `10` recebe a mesma quantidade de possibilidades na transformação aceita.

**O total apostado em cada número não entra no cálculo do número vencedor.**

## `jl_finalize_due_rounds()`

Para ver o código completo:

```sql
select pg_get_functiondef(
  'public.jl_finalize_due_rounds()'::regprocedure
);
```

Essa função procura rodadas abertas ou fechadas cujo `closes_at <= now()`, sorteia o número, grava o resultado, calcula vencedores, calcula `amount × 10`, credita os saldos, registra as transações e publica a rodada.

# Como as apostas e os valores são guardados

Esta parte é importante: **o sistema não guarda apenas um total por número**. Cada aposta individual fica registrada na tabela `public.bets`.

Principais colunas de `bets`:

```text
id               identificador único da aposta
round_id         rodada à qual a aposta pertence
player_id        jogador que apostou
selected_number  número escolhido, de 0 a 10
amount           valor apostado
won              se a aposta venceu ou não
payout           prémio calculado
created_at       data/hora da aposta
```

Exemplo de apostas individuais:

```text
Jogador A → número 0 → 100 MZN
Jogador B → número 0 → 50 MZN
Jogador C → número 7 → 20 MZN
```

O banco guarda três linhas distintas em `bets`.

Conceitualmente:

```text
selected_number = 0 | amount = 100
selected_number = 0 | amount = 50
selected_number = 7 | amount = 20
```

O total do número `0` não precisa ser armazenado numa coluna separada. Ele é calculado quando necessário:

```text
100 + 50 = 150 MZN apostados no número 0
```

## Função que grava a aposta: `jl_place_bet(...)`

Para ver a função inteira no SQL Editor:

```sql
select pg_get_functiondef(
  'public.jl_place_bet(text,integer,numeric)'::regprocedure
);
```

A função recebe:

```text
p_token            sessão do jogador
p_selected_number  número escolhido
p_amount            valor da aposta
```

Antes de gravar, ela valida:

```text
número entre 0 e 10
valor válido
rodada aberta
horário ainda não encerrado
jogador autenticado
jogador não bloqueado
saldo suficiente
```

### 1. Localiza a rodada aberta

A função procura uma rodada com:

```sql
status = 'open'
and closes_at > now()
```

Se não existir, devolve erro de apostas fechadas.

### 2. Confere o jogador e o saldo

O jogador é carregado com bloqueio de linha para impedir conflitos simultâneos.

Se o saldo for menor que o valor solicitado, a aposta é recusada.

### 3. Desconta o valor do saldo

A lógica executa:

```sql
update public.players
set
  balance = balance - p_amount,
  updated_at = now()
where id = v_player_id;
```

Exemplo:

```text
Saldo antes: 500 MZN
Aposta:      100 MZN
Saldo depois: 400 MZN
```

### 4. Grava a aposta na tabela `bets`

A parte central é:

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

Exemplo: se um jogador escolher o número `0` e apostar `100 MZN`, a linha gravada terá, conceitualmente:

```text
round_id        = rodada atual
player_id       = jogador autenticado
selected_number = 0
amount          = 100.00
```

Se outro jogador apostar `50 MZN` no mesmo número, entra outra linha. Nenhuma aposta anterior é substituída.

### 5. Registra também a movimentação financeira

Depois da aposta ser criada, o sistema registra uma transação:

```sql
insert into public.transactions(
  player_id,
  kind,
  amount,
  status,
  reference_id,
  note
)
values(
  v_player_id,
  'bet',
  -round(p_amount, 2),
  'completed',
  v_bet_id,
  'Aposta no Número Lendário'
);
```

O valor aparece negativo na transação porque representa saída do saldo do jogador.

Portanto a mesma aposta deixa dois registros importantes:

```text
bets         → o que foi apostado, em qual número e em qual rodada
transactions → a movimentação financeira correspondente
```

# Como o total de cada número é calculado

O total é calculado a partir das apostas individuais usando `sum(amount)`.

Exemplo simples:

```sql
select
  selected_number,
  count(*) as quantidade_de_apostas,
  sum(amount) as total_apostado
from public.bets
group by selected_number
order by selected_number;
```

Para uma rodada específica, o filtro é feito por `round_id`.

A função administrativa `jl_admin_dashboard(...)` já faz essa agregação para a rodada atual:

```sql
select
  selected_number,
  count(*)::int as bet_count,
  sum(amount)::numeric as total
from public.bets
where round_id = v_round.id
group by selected_number;
```

Depois ela combina o resultado com `generate_series(0,10)` para que números sem apostas também apareçam com zero.

Assim o painel pode mostrar:

```text
Número 0  → 3 apostas → 170 MZN
Número 1  → 0 apostas →   0 MZN
Número 2  → 5 apostas → 420 MZN
...
Número 10 → 2 apostas →  80 MZN
```

## Consulta para ver os totais da rodada atualmente aberta

No SQL Editor:

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

## Consulta para ver cada aposta individual

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

## Regra de independência do sorteio

Os valores agregados servem para administração e relatórios. Eles **não alteram a probabilidade do sorteio**.

```text
total apostado no 0 = informação administrativa
total apostado no 7 = informação administrativa

jl_secure_number() = sorteio independente desses totais
```

Portanto o sistema não escolhe um número com base em qual número possui mais ou menos dinheiro apostado.

# Fluxo completo da rodada

```text
Administrador define a hora
        ↓
Supabase grava closes_at
        ↓
Rodada fica OPEN
        ↓
Jogador escolhe número e valor
        ↓
jl_place_bet(...)
        ↓
valida saldo e horário
        ↓
desconta saldo
        ↓
grava linha em bets
        ↓
grava transação financeira
        ↓
admin pode ver quantidade e total por número
        ↓
hora chega
        ↓
jl_finalize_due_rounds()
        ↓
jl_secure_number()
        ↓
sorteia 0..10
        ↓
compara selected_number com drawn_number
        ↓
marca vencedores
        ↓
payout = amount × 10
        ↓
credita saldos
        ↓
registra pagamentos
        ↓
publica resultado
```

# Administração

O administrador pode:

- definir a data e hora do sorteio;
- abrir uma rodada;
- acompanhar o tempo restante;
- ver quantidade de apostas por número;
- ver o total apostado por número;
- ver apostas recentes;
- ver o último resultado;
- aprovar/rejeitar depósitos;
- autorizar/rejeitar saques;
- ajustar saldo;
- bloquear/desbloquear jogador;
- usar a ação de emergência para encerrar/sortear agora quando necessário.

Não existe escolha manual normal do número vencedor.

# Cadastro e login

A conta usa:

- nome;
- número de telefone;
- PIN de 4 a 8 dígitos.

O PIN é armazenado como hash. As sessões usam tokens cuja forma original não fica armazenada diretamente como senha reutilizável.

# Depósitos

```text
jogador solicita depósito
        ↓
pedido fica pendente
        ↓
administrador aprova ou rejeita
        ↓
se aprovado, saldo aumenta
```

Nesta fase o sistema não executa automaticamente uma transferência real por M-Pesa ou banco.

# Saques

Saldo insuficiente:

```text
pedido
  ↓
rejeição automática
```

Saldo suficiente:

```text
valor é reservado
        ↓
pedido fica pendente
        ↓
administrador aprova ou rejeita
        ↓
aprovado = valor permanece debitado
rejeitado = valor volta ao saldo
```

# Banco de dados

Principais tabelas:

```text
players
player_sessions
game_rounds
bets
deposit_requests
withdrawal_requests
transactions
admin_sessions
admin_config
audit_log
```

As tabelas privadas são protegidas e o navegador trabalha através de funções RPC específicas.

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
```

Admin local:

```text
http://localhost:8080/admin.html
```

Se já tiver clonado antes:

```bash
cd jogos-lendarios
git status
git switch main
git pull origin main
```

# Fluxo obrigatório de cada retificação

```text
atualizar main
    ↓
fazer alteração
    ↓
testar localmente
    ↓
git diff
    ↓
commit
    ↓
push main
    ↓
Cloudflare detecta commit
    ↓
build/deploy automático
    ↓
testar produção
```

Comandos básicos:

```bash
git switch main
git pull origin main

# fazer a retificação

python3 -m http.server 8080

git status
git diff
git add .
git commit -m "Descrição clara da retificação"
git push origin main
```

Para mudanças de banco, usar migration no Supabase e testar as RPCs afetadas. Mudanças estruturais no banco podem afetar produção imediatamente, por isso devem ser tratadas com cuidado.

Nunca enviar ao GitHub:

- senha do banco;
- `service_role`;
- chaves privadas;
- tokens administrativos;
- segredos de infraestrutura.

# Como colocar online e em produção

A configuração inicial já está pronta:

```text
GitHub:     Progaminy/jogos-lendarios
Branch:     main
Cloudflare: Worker jogos-lendarios
Assets:     raiz do repositório
Domínio:    jogoslendarios.adadpsf.shop
```

Depois da primeira configuração, não recriar o projeto nem fazer upload manual dos ficheiros.

Para publicar uma retificação:

```bash
git add .
git commit -m "Descrição da retificação"
git push origin main
```

Depois:

```text
GitHub main
    ↓
Cloudflare detecta o commit
    ↓
novo deploy
    ↓
https://jogoslendarios.adadpsf.shop
```

Confirmar no Cloudflare:

```text
Workers e Pages
→ jogos-lendarios
→ Implantações
```

E testar:

```text
https://jogoslendarios.adadpsf.shop
https://jogoslendarios.adadpsf.shop/admin.html
```

# Rollback

Para desfazer um commit sem apagar o histórico:

```bash
git log --oneline
git revert <SHA_DO_COMMIT>
git push origin main
```

Para alterações no Supabase, fazer uma migration corretiva compatível em vez de apagar dados de produção sem análise.

# Checklist antes de considerar uma retificação concluída

- código atualizado a partir da `main`;
- alteração feita somente onde necessário;
- teste local realizado;
- `git diff` conferido;
- nenhum segredo adicionado ao repositório;
- commit com mensagem clara;
- `git push origin main` concluído;
- deploy do Cloudflare concluído;
- domínio de produção testado;
- `/admin.html` testado quando aplicável;
- Supabase/RPC testado quando a mudança envolve banco;
- fluxo afetado testado do início ao fim.

# Regra central

```text
ADMIN define a hora
        ↓
SUPABASE controla a hora oficial
        ↓
JOGO recebe apostas
        ↓
CADA APOSTA é gravada individualmente em bets
        ↓
TOTAIS por número são calculados com SUM(amount)
        ↓
HORA chega
        ↓
SISTEMA fecha apostas
        ↓
SISTEMA sorteia independentemente dos totais
        ↓
SISTEMA calcula vencedores
        ↓
SISTEMA paga vencedores
        ↓
SISTEMA publica resultado
```

**O sorteio é automático ao chegar a hora definida. Cada aposta fica guardada individualmente no Supabase, os totais por número são calculados a partir dessas apostas e não influenciam o número sorteado.**

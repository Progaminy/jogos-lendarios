# Jogos Lendários

Plataforma com **dois jogos independentes** que partilham apenas a conta e o saldo do jogador.

1. **Número Lendário** — escolher 1 número de `0` a `10`.
2. **Dupla Lendária** — escolher 2 números diferentes de `0` a `10`.

Cada jogo possui **apostas, rodadas, programação, bloqueio, resultado, multiplicador, limites e modo de sorteio próprios**.

## Endereços

Produção:

```text
https://jogoslendarios.adadpsf.shop
```

Administração:

```text
https://jogoslendarios.adadpsf.shop/admin.html
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
Frontend público + painel admin

Supabase/PostgreSQL
   ├── jogadores e sessões
   ├── saldo comum
   ├── apostas Número Lendário
   ├── apostas Dupla Lendária
   ├── rodadas separadas por game_type
   ├── horários separados por game_type
   ├── configurações separadas
   ├── depósitos e saques
   ├── transações
   ├── auditoria
   └── lógica real dos sorteios
```

A lógica sensível fica no **Supabase**, não no JavaScript do navegador.

# Regra central: dois jogos realmente separados

Cada rodada em `public.game_rounds` possui:

```text
game_type = number | pair
```

Cada horário em `public.draw_schedule` também possui:

```text
game_type = number | pair
```

Portanto é possível ter, por exemplo:

```text
Número Lendário
sorteios: 30 em 30 minutos
multiplicador: 10×
bloqueio: 3 s

Dupla Lendária
sorteios: 60 em 60 minutos
multiplicador: 50×
bloqueio: 5 s
```

Uma rodada de um jogo não abre, fecha, sorteia nem paga o outro.

# Número Lendário

## Escolha

```text
0, 1, 2, 3, 4, 5, 6, 7, 8, 9 ou 10
```

O jogador escolhe **um número**.

Configuração padrão:

```text
aposta mínima: 10 MZN
aposta máxima: 500 MZN
multiplicador: 10×
bloqueio: 3 segundos
modo: house_min
```

Exemplo:

```text
aposta: 10 MZN
resultado: número escolhido
prémio: 10 × 10 = 100 MZN
```

Tabela das apostas:

```text
public.bets
```

RPC de aposta:

```text
public.jl_place_bet(text, integer, numeric)
```

# Dupla Lendária

## Escolha

O jogador escolhe **dois números diferentes de 0 a 10**.

Exemplos válidos:

```text
0 + 1
0 + 9
1 + 9
4 + 10
9 + 10
```

A ordem não importa:

```text
0 + 9 = 9 + 0
1 + 9 = 9 + 1
```

A combinação é sempre normalizada no banco:

```text
number_a = menor número
number_b = maior número
```

O mesmo número duas vezes continua inválido:

```text
5 + 5 → inválido
0 + 0 → inválido
```

Como existem 11 números (`0..10`) e escolhemos 2 diferentes sem ordem:

```text
C(11,2) = 55 combinações
```

Configuração padrão:

```text
aposta mínima: 10 MZN
aposta máxima: 500 MZN
multiplicador: 50×
bloqueio: 3 segundos
modo: house_min
```

Exemplo:

```text
aposta: 10 MZN
combinação: 0 + 9
resultado: 0 + 9
prémio: 10 × 50 = 500 MZN
```

Tabela das apostas:

```text
public.pair_bets
```

RPC de aposta:

```text
public.jl_place_pair_bet(text, integer, integer, numeric)
```

# Proteção financeira da casa

A proteção é calculada **separadamente em cada jogo**.

Dinheiro apostado no Número Lendário nunca é usado para cobrir a Dupla Lendária e vice-versa.

Antes de aceitar uma aposta, o banco calcula se continuará existindo pelo menos um resultado financeiramente seguro para aquela rodada. Se a nova aposta destruir a última opção segura, ela é recusada.

Mensagem típica:

```text
Esta aposta atingiria o limite de segurança da rodada.
Escolha outro número/combinação ou aguarde a próxima rodada.
```

A regra real deve ser apresentada de forma transparente no produto. O frontend informa o modo de sorteio ativo.

# Modos de sorteio

Cada jogo pode ser configurado independentemente.

## `house_min` — menor exposição

Fluxo:

```text
somar apostas por resultado
      ↓
encontrar a menor exposição
      ↓
selecionar todos os resultados empatados nessa menor exposição
      ↓
sortear aleatoriamente dentro desse grupo
```

### Número Lendário

São 11 resultados possíveis:

```text
0..10
```

A exposição de cada número é:

```text
SUM(amount)
```

Função:

```text
public.jl_secure_number(uuid)
```

### Dupla Lendária

São 55 resultados possíveis:

```text
0+1
0+2
...
0+10
1+2
...
9+10
```

A exposição de cada combinação é:

```text
SUM(amount)
```

Função:

```text
public.jl_secure_pair(uuid)
```

## `house_safe_random` — aleatório entre resultados seguros

Em vez de usar apenas a menor exposição, o sistema cria uma lista de todos os resultados que satisfazem:

```text
exposição × multiplicador < total apostado na rodada
```

Depois escolhe aleatoriamente entre esses resultados seguros.

A escolha dentro da lista usa geração criptográfica e rejeição antes do módulo para evitar viés.

# Matemática padrão

Com as configurações padrão:

```text
Número Lendário: 11 resultados, prémio 10×
Dupla Lendária: 55 resultados, prémio 50×
```

No modo de menor exposição, o sistema observa o resultado menos carregado financeiramente antes de sortear entre empates.

O painel administrativo mostra em tempo real, para **cada jogo**:

```text
total apostado
menor exposição
pagamento correspondente à menor exposição
margem no resultado de menor exposição
quantidade de resultados seguros / resultados possíveis
```

# Administração — mesmo poder nos dois jogos

O painel administrativo foi desenhado para que **Número Lendário e Dupla Lendária tenham os mesmos controlos**.

Para cada jogo, separadamente, o administrador pode:

```text
ativar/desativar
alterar aposta mínima
alterar aposta máxima
alterar multiplicador
alterar segundos de bloqueio
escolher modo de sorteio
abrir rodada manual
encerrar e sortear agora
programar primeiro e último horário
escolher intervalo em minutos
usar atalho próximas 12h
usar atalho próximas 24h
adicionar horário avulso
cancelar um horário
cancelar todos os horários futuros
ver total por número/combinação
ver últimas apostas
ver total apostado
ver menor exposição
ver margem financeira
ver quantidade de resultados seguros
```

As regras de um jogo só podem ser alteradas quando esse jogo não possui rodada ativa.

# Motor automático

Função central:

```text
public.jl_process_game_engine()
```

Ela processa os dois motores separadamente:

```text
jl_process_game('number')
jl_process_game('pair')
```

Cada jogo segue:

```text
programação própria
      ↓
rodada OPEN
      ↓
closes_at
      ↓
LOCKED
      ↓
draw_at
      ↓
sorteio daquele jogo
      ↓
pagamento daquele jogo
      ↓
PUBLISHED
      ↓
próxima rodada programada daquele jogo
```

# Funções administrativas principais

```text
jl_admin_open_game_round(...)
jl_admin_close_game_round(...)
jl_admin_schedule_game_draws(...)
jl_admin_add_game_draw_time(...)
jl_admin_cancel_game_draw_time(...)
jl_admin_clear_game_schedule(...)
jl_admin_update_game_settings(...)
jl_admin_dashboard(...)
jl_admin_game_snapshot(...)
```

Todas recebem ou trabalham com:

```text
game_type = number | pair
```

# Configurações

Tabela:

```text
public.game_settings
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

Configuração padrão atual:

```text
number | 10 | 500 | 10 | 3 | house_min | true
pair   | 10 | 500 | 50 | 3 | house_min | true
```

# Saldo insuficiente

Se o jogador tentar apostar acima do saldo disponível:

```text
Apostar
   ↓
saldo insuficiente
   ↓
aposta não é gravada
   ↓
frontend direciona para DEPÓSITO
```

Isto vale para os dois jogos.

# Depósitos e saques

O saldo é comum à conta.

Depósito:

```text
jogador solicita
→ pending
→ admin aprova/rejeita
→ aprovado aumenta saldo
```

Saque:

```text
saldo insuficiente → rejeição automática
saldo suficiente → valor reservado → admin decide
```

# Estrutura principal

```text
jogos-lendarios/
├── index.html
├── styles.css
├── config.js
├── app.js
├── bet-guard.js
├── admin.html
├── admin.js
├── admin-power.js
├── wrangler.jsonc
├── .assetsignore
├── .gitignore
├── .nojekyll
└── supabase/
    └── migrations/
        ├── 20260916_scheduled_rounds_with_three_second_lock.sql
        ├── 20260916_add_locked_round_state.sql
        ├── 20260916_bet_limits_10_500.sql
        ├── 20260916_add_dupla_lendaria_game.sql
        ├── 20260916_separate_number_pair_games.sql
        └── 20260916_dupla_zero_to_ten_admin_parity.sql
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

Sempre seguir:

```text
1. git switch main
2. git pull origin main
3. alterar apenas o necessário
4. testar localmente
5. verificar git status
6. verificar git diff
7. se houver mudança de banco, criar migration nova
8. aplicar/testar a migration no Supabase
9. git add .
10. git commit -m "Descrição clara"
11. git push origin main
12. Cloudflare detecta o push
13. aguardar implantação
14. testar produção
15. testar também admin e Supabase quando afetados
```

Não editar uma cópia diferente manualmente no Cloudflare.

# Como localizar a lógica do sorteio

Número Lendário:

```sql
select pg_get_functiondef(
  'public.jl_secure_number(uuid)'::regprocedure
);
```

Dupla Lendária:

```sql
select pg_get_functiondef(
  'public.jl_secure_pair(uuid)'::regprocedure
);
```

Validação da aposta simples:

```sql
select pg_get_functiondef(
  'public.jl_place_bet(text,integer,numeric)'::regprocedure
);
```

Validação da Dupla:

```sql
select pg_get_functiondef(
  'public.jl_place_pair_bet(text,integer,integer,numeric)'::regprocedure
);
```

Motor de um jogo:

```sql
select pg_get_functiondef(
  'public.jl_process_game(text)'::regprocedure
);
```

# Consultas úteis

Configurações:

```sql
select *
from public.game_settings
order by game_type;
```

Rodadas:

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
  pair_drawn_b,
  published_at
from public.game_rounds
order by opened_at desc;
```

Programação:

```sql
select game_type, draw_at, status, round_id
from public.draw_schedule
order by game_type, draw_at;
```

Apostas Número Lendário:

```sql
select selected_number, count(*) as apostas, sum(amount) as total
from public.bets
group by selected_number
order by selected_number;
```

Apostas Dupla Lendária:

```sql
select number_a, number_b, count(*) as apostas, sum(amount) as total
from public.pair_bets
group by number_a, number_b
order by number_a, number_b;
```

# Segurança

`config.js` deve conter apenas dados públicos necessários ao navegador:

```text
Supabase URL
publishable key
```

Nunca guardar no GitHub:

```text
service_role
senha do banco
chaves privadas
tokens administrativos
segredos de infraestrutura
```

# Resumo operacional

```text
NÚMERO LENDÁRIO                     DUPLA LENDÁRIA
0..10                               0..10
1 número                             2 números diferentes
11 resultados                        55 combinações
10× padrão                           50× padrão
rodada própria                       rodada própria
programação própria                  programação própria
resultado próprio                    resultado próprio
configuração própria                 configuração própria
proteção financeira própria          proteção financeira própria
mesmo poder administrativo           mesmo poder administrativo
```

O saldo da conta é compartilhado. **Todo o resto dos dois jogos é administrado e calculado separadamente.**

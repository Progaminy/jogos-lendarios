# Jogos Lendários

Projeto organizado para funcionar primeiro com **GitHub Pages + Supabase**. O Cloudflare fica para depois, quando o jogo estiver estável.

## Arquitetura

```text
GitHub Pages = interface do jogador e administração
Supabase     = banco de dados, contas, saldos, apostas e lógica real do sorteio
Cloudflare   = somente depois, para domínio/CDN
```

Não existe `server.js`, `package.json` nem pasta `public/` para publicar o frontend. Os ficheiros do site ficam diretamente na raiz do repositório.

## Estrutura do frontend

```text
jogos-lendarios/
├── index.html      # interface do jogador
├── styles.css      # aparência do site
├── config.js       # URL e publishable key do Supabase
├── app.js          # comunicação do jogador com o Supabase
├── admin.html      # interface administrativa
├── admin.js        # comunicação do administrador com o Supabase
├── README.md
└── .nojekyll
```

**Importante:** a lógica que decide o número vencedor NÃO está em `app.js` nem em `admin.js`.

O GitHub contém o frontend. A lógica sensível do jogo fica no banco PostgreSQL do **Supabase**, para que o jogador não possa alterar o sorteio pelo navegador.

# Jogo: Número Lendário

O jogador escolhe um número inteiro de **0 a 10**, informa o valor e clica em **Apostar**.

Fluxo do jogador:

1. escolhe um número de 0 a 10;
2. informa o valor da aposta;
3. clica em **Apostar**;
4. se ainda não tiver conta, aparece o cadastro;
5. informa nome, telefone, PIN e confirmação do PIN;
6. depois do cadastro/login, a aposta pendente continua;
7. o valor é descontado do saldo;
8. o jogador acompanha o cronómetro da rodada;
9. na hora definida pelo administrador, as apostas fecham automaticamente;
10. o Supabase sorteia automaticamente um número;
11. os vencedores são calculados e os prémios são creditados;
12. o resultado é publicado automaticamente para os jogadores.

Quem acertar recebe **10× o valor apostado**.

# ONDE ESTÁ A LÓGICA DO SORTEIO

A lógica real do sorteio está **no Supabase**, dentro de funções PostgreSQL. Ela não depende do JavaScript do navegador.

Os componentes principais são:

```text
admin.html / admin.js
        │
        │ administrador informa a hora
        ▼
Supabase RPC: jl_admin_open_round(...)
        │
        │ grava a rodada e o campo closes_at
        ▼
game_rounds
        │
        │ pg_cron verifica a hora
        ▼
job: jogos_lendarios_auto_draw
        │
        ▼
função: jl_finalize_due_rounds()
        │
        │ encontrou rodada cuja hora chegou
        ▼
função interna de aleatoriedade: jl_secure_number()
        │
        ▼
número vencedor 0..10
        │
        ├── marca apostas vencedoras
        ├── calcula prémios
        ├── atualiza saldos
        ├── registra transações
        └── publica o resultado
```

## Funções responsáveis

### `jl_admin_open_round(...)`

É chamada quando o administrador abre uma rodada.

Responsabilidade:

```text
receber a data/hora escolhida
        ↓
validar a data/hora
        ↓
criar a rodada
        ↓
grava closes_at no banco
```

A partir desse momento, a hora não depende do navegador do administrador.

### `jl_finalize_due_rounds()`

É a função de **finalização automática da rodada**.

Ela procura rodadas abertas cuja `closes_at` já chegou. Quando encontra uma rodada vencida, executa o processo do sorteio uma única vez.

Responsabilidade conceitual:

```text
verificar hora do servidor
        ↓
localizar rodada vencida
        ↓
impedir novas apostas
        ↓
gerar número vencedor
        ↓
identificar vencedores
        ↓
calcular pagamento
        ↓
creditar saldo
        ↓
registrar transações
        ↓
publicar resultado
```

### `jl_secure_number()`

É a função interna que gera o número vencedor.

Ela trabalha no banco e usa `pgcrypto`. Os números possíveis são:

```text
0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
```

A lógica de distribuição é:

```text
1. gerar um byte criptograficamente aleatório entre 0 e 255
2. aceitar apenas valores de 0 a 252
3. se cair 253, 254 ou 255, gerar novamente
4. calcular valor % 11
5. resultado final fica entre 0 e 10
```

Como existem 253 valores aceitos e:

```text
253 = 23 × 11
```

cada número de 0 a 10 recebe exatamente 23 possibilidades nessa transformação.

O total apostado em cada número **não entra nesse cálculo**.

## Onde ver essas funções no Supabase

No projeto Supabase, a lógica pode ser inspecionada no banco de dados. As funções importantes a procurar são:

```text
jl_admin_open_round
jl_finalize_due_rounds
jl_secure_number
```

O agendamento automático a procurar é:

```text
jogos_lendarios_auto_draw
```

Assim, quem clonar somente o repositório GitHub verá o frontend, mas a lógica protegida do sorteio continuará no Supabase.

# FLUXO COMPLETO DA RODADA

## 1. Administrador define a hora

No painel `admin.html`, o administrador escolhe a data e hora de encerramento/sorteio.

Exemplo:

```text
Agora: 18:00
Sorteio definido para: 19:30
```

`admin.js` envia essa informação ao Supabase através da função administrativa.

## 2. Supabase cria a rodada

O banco grava algo equivalente a:

```text
status     = open
opened_at  = hora de abertura
closes_at  = 19:30
```

A partir daqui a hora oficial é a hora armazenada no Supabase.

## 3. Jogadores apostam

Enquanto:

```text
hora atual < closes_at
```

o jogador pode escolher um número e apostar.

A aposta é registrada na tabela `bets` e vinculada à rodada atual.

## 4. Cronómetro chega a zero

O contador mostrado no site é apenas uma representação visual.

A regra verdadeira está no servidor:

```text
now() >= closes_at
```

Portanto, alterar o relógio do computador ou o JavaScript do navegador não prolonga as apostas.

## 5. Agendamento automático detecta a rodada

O Supabase usa `pg_cron` com o job:

```text
jogos_lendarios_auto_draw
```

Ele executa periodicamente:

```text
jl_finalize_due_rounds()
```

O administrador não precisa estar com o painel aberto e nenhum jogador precisa estar com o site aberto para o processo acontecer.

## 6. Apostas são encerradas

Quando a hora chega, a rodada deixa de aceitar apostas.

Uma tentativa enviada depois da hora deve ser recusada pelo próprio banco, mesmo que alguém tente chamar a API manualmente.

## 7. Número é sorteado

A função de finalização chama a lógica segura de geração do número.

```text
jl_finalize_due_rounds()
        ↓
jl_secure_number()
        ↓
0..10
```

Esse número é gravado na rodada e não pode ser trocado por outro sorteio da mesma rodada.

## 8. Vencedores são calculados

O banco compara:

```text
selected_number == drawn_number
```

Quem acertou é marcado como vencedor.

## 9. Prémios são calculados

Para cada aposta vencedora:

```text
prémio = valor_apostado × 10
```

Exemplo:

```text
Aposta: 50 MZN
Número escolhido: 7
Número sorteado: 7
Prémio: 500 MZN
```

## 10. Saldos são atualizados

O valor do prémio é creditado automaticamente no saldo do jogador vencedor.

Também é criada uma transação para manter o histórico financeiro do sistema.

## 11. Resultado é publicado

O número vencedor passa a ficar disponível para o estado público do jogo.

`app.js` consulta o Supabase periodicamente e mostra o novo resultado aos jogadores.

O frontend **não cria o resultado**; apenas exibe o resultado já decidido e gravado pelo banco.

## Fluxo resumido

```text
ADMIN define a hora
        ↓
Supabase grava closes_at
        ↓
JOGO fica aberto
        ↓
JOGADORES apostam
        ↓
cronómetro chega a zero
        ↓
pg_cron detecta rodada vencida
        ↓
jl_finalize_due_rounds()
        ↓
SISTEMA fecha apostas
        ↓
jl_secure_number()
        ↓
SISTEMA sorteia 0..10
        ↓
SISTEMA identifica vencedores
        ↓
SISTEMA calcula 10×
        ↓
SISTEMA atualiza saldos
        ↓
SISTEMA registra transações
        ↓
SISTEMA publica resultado
        ↓
app.js mostra o resultado
```

# SORTEIO AUTOMÁTICO

Esta é uma regra principal do projeto:

**o administrador NÃO escolhe quando clicar para sortear depois de ver as apostas.**

Ao abrir uma rodada, o administrador define a **data e hora do sorteio**. A partir daí o sistema trabalha sozinho.

Tudo acontece no banco de dados, sem botão normal de “Sortear” e sem botão de “Publicar resultado”.

O painel pode manter apenas uma ação administrativa de emergência **Encerrar e sortear agora**. Essa ação antecipa o mesmo processo, mas não permite escolher o número nem repetir o sorteio da rodada.

# ADMINISTRAÇÃO

O painel está em:

```text
/admin.html
```

O administrador pode:

- definir data e hora do sorteio;
- abrir uma rodada;
- acompanhar o tempo restante;
- encerrar e sortear imediatamente em caso de necessidade;
- ver total apostado em cada número;
- ver quantidade de apostas por número;
- ver último resultado;
- aprovar ou rejeitar depósitos;
- autorizar ou rejeitar saques;
- ajustar saldo;
- bloquear ou desbloquear jogador;
- ver apostas recentes.

Não existe escolha manual do número vencedor.

# CADASTRO E LOGIN

A conta usa:

- nome;
- número de telefone;
- PIN de 4 a 8 dígitos.

O PIN não é guardado em texto puro. O banco guarda hash. As sessões também usam tokens cujo valor original não fica armazenado diretamente no banco.

# DEPÓSITOS

O sistema atual registra **pedidos de depósito**.

Fluxo:

```text
jogador pede depósito
        ↓
pedido fica pendente
        ↓
administrador aprova ou rejeita
        ↓
se aprovado, saldo aumenta
```

Nesta fase o sistema ainda não executa automaticamente uma transferência real por M-Pesa ou banco.

# SAQUES

Ao pedir saque:

```text
saldo insuficiente
        ↓
rejeição automática
```

ou:

```text
saldo suficiente
        ↓
valor é reservado
        ↓
pedido fica pendente
        ↓
administrador aprova ou rejeita
        ↓
aprovado = valor permanece debitado
rejeitado = valor volta ao saldo
```

Isso evita que o mesmo saldo seja usado para vários pedidos simultâneos.

# BANCO DE DADOS

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

As tabelas usam RLS. O navegador não recebe acesso direto às tabelas privadas; utiliza funções RPC específicas.

# TESTAR LOCALMENTE

Depois de clonar:

```bash
git clone https://github.com/Progaminy/jogos-lendarios.git
cd jogos-lendarios
python3 -m http.server 8080
```

Abrir:

```text
http://localhost:8080
```

Administração:

```text
http://localhost:8080/admin.html
```

Os caminhos são relativos (`./styles.css`, `./app.js`, etc.), portanto o mesmo frontend funciona localmente e no GitHub Pages.

**Observação importante:** rodar localmente testa o frontend, mas o sorteio continua sendo executado no Supabase. Não existe uma segunda lógica de sorteio local no JavaScript.

# FAZER ALTERAÇÕES

Fluxo normal:

```bash
git add .
git commit -m "melhoria do jogo"
git push origin main
```

O GitHub Pages publica a branch `main` a partir de `/ (root)`.

Página esperada:

```text
https://progaminy.github.io/jogos-lendarios/
```

# SUPABASE NO FRONTEND

`config.js` contém somente:

- URL pública do projeto;
- publishable key.

A publishable key pode ficar no frontend. Nunca colocar no GitHub:

- `service_role`;
- senha do banco;
- chaves privadas;
- segredos administrativos.

# CLOUDFLARE

Nesta fase não é necessário Cloudflare.

A ordem é:

```text
1. funcionar localmente
2. funcionar no GitHub
3. funcionar no GitHub Pages
4. funcionar corretamente com Supabase
5. somente depois ligar Cloudflare
```

Assim evitamos voltar a ter versões diferentes do mesmo site em vários lugares.

# REGRA CENTRAL

```text
ADMIN define a hora
        ↓
SUPABASE controla a hora oficial
        ↓
JOGO recebe apostas
        ↓
HORA chega
        ↓
SISTEMA fecha apostas
        ↓
SISTEMA sorteia automaticamente
        ↓
SISTEMA calcula vencedores
        ↓
SISTEMA paga vencedores
        ↓
SISTEMA publica resultado
```

**O sorteio é automático ao chegar a hora definida, e a lógica do número vencedor fica no Supabase, não no navegador.**

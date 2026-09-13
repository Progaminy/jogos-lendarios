# Jogos Lendários

Projeto organizado para funcionar primeiro com **GitHub Pages + Supabase**. O Cloudflare fica para depois, quando o jogo estiver estável.

## Arquitetura

```text
GitHub Pages = interface do jogador e administração
Supabase     = banco de dados, contas, saldos, apostas e sorteio
Cloudflare   = somente depois, para domínio/CDN
```

Não existe `server.js`, `package.json` nem pasta `public/` para publicar o frontend. Os ficheiros do site ficam diretamente na raiz do repositório.

## Estrutura

```text
jogos-lendarios/
├── index.html
├── styles.css
├── config.js
├── app.js
├── admin.html
├── admin.js
├── README.md
└── .nojekyll
```

## Jogo: Número Lendário

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

# SORTEIO AUTOMÁTICO

Esta é uma regra principal do projeto:

**o administrador NÃO escolhe quando clicar para sortear depois de ver as apostas.**

Ao abrir uma rodada, o administrador define a **data e hora do sorteio**. A partir daí o sistema trabalha sozinho.

Exemplo:

```text
Abrir rodada: 18:00
Hora definida para sorteio: 19:30
```

Até 19:30 os jogadores podem apostar. Quando a hora chega:

```text
1. apostas são encerradas
2. número é sorteado
3. apostas vencedoras são identificadas
4. prémios são calculados
5. saldo dos vencedores é atualizado
6. resultado é publicado
```

Tudo isso acontece no banco de dados, sem botão manual de “Sortear” e sem botão manual de “Publicar resultado”.

O painel mantém apenas um botão de emergência **Encerrar e sortear agora**. Esse botão antecipa o mesmo processo automático e não permite escolher o número.

## Agendamento no Supabase

O Supabase usa `pg_cron` com o trabalho:

```text
jogos_lendarios_auto_draw
```

Ele verifica continuamente as rodadas vencidas. A função interna responsável é:

```text
jl_finalize_due_rounds()
```

Ela não é exposta diretamente aos jogadores.

Além do agendamento, as consultas de estado também verificam se a hora já passou. Isso cria uma segunda proteção: se uma rodada venceu, a próxima atualização do site também força a finalização automática.

## Aleatoriedade

Os números possíveis são:

```text
0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
```

O valor apostado em cada número **não influencia o resultado**.

O banco usa `pgcrypto` para gerar aleatoriedade criptográfica. Para evitar viés de módulo:

```text
1. gera um byte aleatório entre 0 e 255
2. aceita apenas valores entre 0 e 252
3. calcula valor % 11
4. resultado final fica entre 0 e 10
```

Como `253 = 23 × 11`, cada número recebe exatamente a mesma quantidade de valores possíveis nessa transformação.

Cada rodada é sorteada apenas uma vez.

## Administração

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

Não existem botões de sorteio repetido nem escolha manual do número vencedor.

## Cadastro e login

A conta usa:

- nome;
- número de telefone;
- PIN de 4 a 8 dígitos.

O PIN não é guardado em texto puro. O banco guarda hash. As sessões também usam tokens cujo valor original não fica armazenado diretamente no banco.

## Depósitos

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

## Saques

Ao pedir saque:

- saldo insuficiente → rejeição automática;
- saldo suficiente → valor é reservado e pedido fica pendente;
- administrador aprova → saque permanece debitado;
- administrador rejeita → valor volta ao saldo.

Isso evita que o mesmo saldo seja usado para vários pedidos simultâneos.

## Banco de dados

Principais tabelas:

- `players`
- `player_sessions`
- `game_rounds`
- `bets`
- `deposit_requests`
- `withdrawal_requests`
- `transactions`
- `admin_sessions`
- `admin_config`
- `audit_log`

As tabelas usam RLS. O navegador não recebe acesso direto às tabelas privadas; utiliza funções RPC específicas.

## Testar localmente

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

## Fazer alterações

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

## Supabase no frontend

`config.js` contém somente:

- URL pública do projeto;
- publishable key.

A publishable key pode ficar no frontend. Nunca colocar no GitHub:

- `service_role`;
- senha do banco;
- chaves privadas;
- segredos administrativos.

## Cloudflare

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

## Regra central da rodada

```text
ADMIN define a hora
        ↓
JOGO fica aberto
        ↓
cronómetro chega a zero
        ↓
SISTEMA fecha apostas
        ↓
SISTEMA sorteia
        ↓
SISTEMA paga vencedores
        ↓
SISTEMA publica resultado
```

**O sorteio é automático ao chegar a hora definida.**

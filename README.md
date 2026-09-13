# Jogos Lendários

Projeto reconstruído para funcionar de forma simples no desenvolvimento e na publicação:

- **Frontend estático no GitHub Pages**
- **Banco de dados e lógica segura no Supabase**
- **Sem Node.js no frontend**
- **Sem pasta `public/`**
- **Sem Cloudflare nesta fase**

A ideia é que o fluxo de trabalho seja o mesmo de outros projetos simples: editar os ficheiros, testar localmente, fazer `git add`, `git commit`, `git push` e ver a nova versão no GitHub Pages.

## Jogo atual: Número Lendário

O jogador escolhe um número inteiro entre **0 e 10**. Depois informa o valor da aposta e clica em **Apostar**.

A conta **não é exigida antes de escolher o número**. O fluxo correto é:

1. jogador escolhe um número de 0 a 10;
2. informa o valor da aposta;
3. clica em **Apostar**;
4. se ainda não tiver sessão, aparece o cadastro;
5. no cadastro informa nome, número de celular, PIN e confirmação do PIN;
6. depois do cadastro/login, a aposta pendente continua automaticamente;
7. o valor é descontado do saldo;
8. quando a rodada fecha, não são aceites novas apostas;
9. o administrador executa o sorteio;
10. o resultado é publicado para todos;
11. quem acertar recebe **10× o valor apostado**.

## Estrutura

```text
jogos-lendarios/
├── index.html      # página principal do jogador
├── styles.css      # visual responsivo
├── config.js       # URL e publishable key do Supabase
├── app.js          # lógica do jogador
├── admin.html      # painel administrativo
├── admin.js        # lógica administrativa
├── README.md
└── .nojekyll
```

Não existe necessidade de `server.js`, `package.json` nem `public/` para publicar este frontend no GitHub Pages.

## Testar localmente

### Opção recomendada

Dentro da pasta clonada:

```bash
python3 -m http.server 8080
```

Depois abrir:

```text
http://localhost:8080
```

O painel administrativo fica em:

```text
http://localhost:8080/admin.html
```

Como todos os caminhos são relativos (`./styles.css`, `./app.js`, etc.), a mesma estrutura funciona localmente e no GitHub Pages.

## Publicar no GitHub

Fluxo normal:

```bash
git add .
git commit -m "melhoria do jogo"
git push origin main
```

No GitHub, em **Settings → Pages**:

- Source: **Deploy from a branch**
- Branch: **main**
- Folder: **/ (root)**

O GitHub Pages deve então servir diretamente o `index.html` que está na raiz do repositório.

URL esperada:

```text
https://progaminy.github.io/jogos-lendarios/
```

O README não deve aparecer como página do jogo porque agora existe um `index.html` na raiz.

## Supabase

O frontend usa o projeto Supabase `jogos-lendarios`.

`config.js` contém apenas:

- URL pública do projeto;
- **publishable key** do Supabase.

A publishable key pode existir no frontend. **Nunca colocar `service_role`, senha do banco ou outras chaves privadas no GitHub.**

### Segurança

As tabelas têm RLS ativo e não são acessadas diretamente pelo navegador.

O frontend usa funções RPC `SECURITY DEFINER` específicas. Assim, a publishable key não dá acesso livre às tabelas.

O PIN do jogador não é guardado em texto puro. Ele é transformado em hash no banco.

As sessões também não são guardadas em texto puro no banco: apenas o hash do token é armazenado.

## Principais tabelas

- `players` — contas, telefone, hash do PIN, saldo e bloqueio;
- `player_sessions` — sessões dos jogadores;
- `game_rounds` — rodadas, horário de fechamento e resultado;
- `bets` — apostas realizadas;
- `deposit_requests` — pedidos de depósito;
- `withdrawal_requests` — pedidos de saque;
- `transactions` — histórico financeiro interno;
- `admin_sessions` — sessões administrativas;
- `admin_config` — configuração segura do acesso administrativo.

## Funções do jogador

O navegador utiliza principalmente:

- `jl_public_state()` — rodada atual e último resultado publicado;
- `jl_register_player(...)` — cria conta;
- `jl_login_player(...)` — login com telefone e PIN;
- `jl_player_state(...)` — saldo, histórico e estado da rodada;
- `jl_place_bet(...)` — registra aposta e desconta saldo;
- `jl_request_deposit(...)` — envia pedido de depósito;
- `jl_request_withdrawal(...)` — envia pedido de saque;
- `jl_logout_player(...)` — encerra sessão.

## Depósitos

O sistema atual **não executa automaticamente uma transferência M-Pesa ou bancária**.

O jogador solicita um depósito. O sistema devolve uma confirmação com o ID do pedido. No painel administrativo, o pedido aparece como pendente.

Quando o administrador aprova:

- o pedido muda para `approved`;
- o saldo do jogador é aumentado;
- uma transação é registrada.

Quando rejeita, o saldo não é alterado.

## Saques

Ao pedir saque:

- se o saldo for insuficiente, o pedido é **rejeitado automaticamente**;
- se houver saldo, o valor é reservado imediatamente e o pedido fica pendente;
- o administrador recebe o pedido no painel;
- se aprovar, o valor permanece retirado;
- se rejeitar, o valor é devolvido automaticamente ao saldo.

Isso evita que o jogador peça vários saques usando o mesmo saldo.

## Administração

O painel fica em:

```text
/admin.html
```

Depois de autenticar, o administrador pode:

- ver a rodada atual;
- definir data e hora de encerramento;
- abrir uma nova rodada;
- fechar apostas manualmente;
- ver o tempo restante;
- ver quantidade de apostas por número;
- ver valor total apostado em cada número;
- sortear o número vencedor;
- publicar o resultado;
- aprovar/rejeitar depósitos;
- autorizar/rejeitar saques;
- ajustar saldo manualmente;
- bloquear/desbloquear jogadores;
- ver apostas recentes.

## Lógica do sorteio

O sorteio não depende de quanto foi apostado em cada número.

Os números possíveis são:

```text
0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
```

Cada rodada só pode ser sorteada **uma vez**.

O banco gera um byte criptograficamente aleatório com `pgcrypto`. Para evitar viés de módulo, valores de byte fora da faixa divisível igualmente por 11 são descartados e outro byte é gerado.

Em termos simplificados:

```text
1. gerar um byte aleatório entre 0 e 255
2. aceitar apenas valores de 0 a 252
3. calcular valor % 11
4. resultado final fica entre 0 e 10
```

Como existem 253 valores aceitos e `253 = 23 × 11`, cada número de 0 a 10 recebe exatamente a mesma quantidade de possibilidades nessa transformação.

Depois do sorteio:

- todas as apostas do número vencedor recebem `won = true`;
- prêmio = `valor apostado × 10`;
- o prêmio é creditado no saldo;
- o administrador apenas publica o resultado já sorteado.

**Não existe botão de “sortear outra vez” para a mesma rodada.** Isso é intencional para impedir que o resultado seja escolhido depois de ver as apostas.

## Cronómetro

Cada rodada tem `closes_at`.

O frontend mostra a contagem regressiva. Mesmo que o navegador do jogador tente enviar a aposta no último segundo, o próprio banco verifica a hora antes de aceitar.

Portanto, esconder ou alterar o relógio pelo navegador não reabre uma rodada.

## Atualização automática

A página do jogador e o painel administrativo consultam o Supabase periodicamente. Assim, saldo, pedidos, encerramento e resultado aparecem sem ser necessário recarregar manualmente toda a página.

## Cloudflare

Cloudflare fica **fora desta etapa**.

Primeiro o projeto deve funcionar corretamente em:

1. local;
2. GitHub;
3. GitHub Pages;
4. Supabase.

Depois disso podemos ligar Cloudflare apenas como camada de domínio/CDN, sem mudar a estrutura do projeto nem criar outra versão paralela.

## Próximos passos

Antes de colocar dinheiro real em produção ainda faltam integrações externas, especialmente confirmação real de pagamentos/saques e validação das regras legais aplicáveis ao serviço.

A base atual já separa corretamente:

```text
GitHub Pages = interface
Supabase = dados + autenticação por PIN + regras do jogo + administração
Cloudflare = somente depois
```

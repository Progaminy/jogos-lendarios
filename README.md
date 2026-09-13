# Jogos Lendários

Protótipo mobile-first do projeto **Jogos Lendários**, com frontend no Cloudflare Pages e backend no Supabase.

> Estado atual: **modo teste**. Os valores mostrados em MTS são valores internos de teste; o repositório não implementa movimentação real de dinheiro.

## Jogo 1 — Número Lendário

O jogador escolhe um número inteiro de **0 a 10** e informa o valor da aposta. Se o número escolhido coincidir com o número publicado da rodada, o prémio é **10× o valor apostado** em saldo de teste.

Exemplo: **10 MTS de teste → 100 MTS de teste** quando o jogador acerta.

## Fluxo do jogador

1. O público abre o site e vê o estado atual da rodada.
2. Quando o administrador abre uma rodada, aparece a contagem regressiva até o horário de fechamento.
3. O jogador escolhe uma bola de **0 a 10**.
4. Informa o valor da aposta e toca em **Apostar**.
5. Se ainda não tiver conta, cria uma usando:
   - nome;
   - número de celular;
   - PIN;
   - confirmação do PIN.
6. Quem já possui conta entra com **celular + PIN**.
7. A aposta fica registrada na rodada e aparece como **pendente** até a publicação do resultado.
8. Depois da publicação, o jogador vê:
   - número escolhido;
   - número sorteado;
   - resultado;
   - prémio quando houver vitória.

## Fluxo da rodada

A rodada passa pelos seguintes estados:

`aberta → fechada → sorteada → publicada`

### 1. Abrir jogo

O administrador define a **data e hora exata de encerramento** e abre a rodada.

Enquanto estiver aberta:

- o público vê o tempo restante em contagem regressiva;
- jogadores podem registrar apostas;
- o painel administrativo mostra quantidade de apostas e valor total apostado em cada número de 0 a 10.

### 2. Fechar apostas

As apostas deixam de ser aceitas quando:

- chega automaticamente o horário definido pelo administrador; ou
- o administrador toca em **Fechar apostas** antes do horário.

Depois do fechamento, nenhuma nova aposta pode entrar naquela rodada.

### 3. Sortear número

O administrador toca em **Sortear número** depois do fechamento.

O backend gera **um único número de 0 a 10**. Depois de gerado, o número fica bloqueado naquela rodada e o sorteio não pode ser repetido.

### 4. Publicar resultado

O número sorteado só se torna público quando o administrador toca em **Publicar resultado**.

Na publicação:

- as apostas da rodada são resolvidas;
- os vencedores são identificados;
- os prémios de teste são creditados;
- o painel mostra a lista de vencedores e o valor do prémio de cada um;
- os jogadores passam a ver o resultado no seu histórico.

## Lógica do número sorteado

O resultado **não depende do volume apostado em cada número**.

Cada número de `0` a `10` tem a mesma probabilidade teórica:

`1 / 11 ≈ 9,09%`

O sorteio é feito no backend com geração criptograficamente segura (`crypto.getRandomValues`). É utilizada rejeição de valores fora de um múltiplo exato de 11 antes do cálculo do resto, evitando viés de módulo.

Em termos simplificados:

1. o servidor gera um inteiro aleatório de 32 bits;
2. descarta valores na pequena faixa que poderia causar distribuição desigual;
3. calcula `valor % 11`;
4. obtém um número entre `0` e `10`;
5. grava esse número na rodada;
6. impede um segundo sorteio para a mesma rodada;
7. aguarda a publicação administrativa.

Assim, o painel pode mostrar quanto foi apostado em cada número, mas essa informação é **estatística** e não altera o resultado.

## Painel administrativo

O painel permite:

- autenticação administrativa por código validado no backend;
- abrir uma rodada;
- definir a hora exata de encerramento;
- fechar apostas manualmente;
- acompanhar o cronómetro;
- ver total de apostas por número;
- ver valor total apostado em cada número;
- sortear um número uma única vez;
- publicar o resultado;
- ver vencedores e respetivos prémios;
- ver jogadores e saldos de teste;
- ajustar saldos de teste;
- bloquear/desbloquear contas;
- aprovar ou rejeitar pedidos de saldo de teste;
- aprovar ou rejeitar pedidos de levantamento de teste;
- conversar com jogadores pela caixa de mensagens;
- consultar auditoria das ações.

## Levantamentos de teste

Quando um jogador solicita levantamento:

1. o backend calcula o **saldo disponível**, descontando valores já reservados em pedidos pendentes;
2. se o saldo disponível for insuficiente, o pedido é **rejeitado automaticamente** e a decisão fica registrada na auditoria;
3. se houver saldo suficiente, o pedido fica **pendente**;
4. o painel administrativo mostra uma notificação de pedido pendente;
5. o admin pode **Aprovar** ou **Rejeitar**;
6. enquanto estiver pendente, o valor fica reservado;
7. o saldo só é efetivamente reduzido quando o admin aprova.

O painel possui ainda opção para ativar notificações do navegador. Enquanto a página administrativa estiver aberta, ela consulta periodicamente se existem novos pedidos pendentes.

## Solicitação de saldo de teste

O jogador informa:

- valor;
- confirmação/referência obrigatória.

O pedido fica pendente até o administrador aprovar ou rejeitar.

## Conta e PIN

As contas usam número de celular único.

O PIN:

- tem de 4 a 8 dígitos;
- não é guardado em texto puro;
- é derivado com **PBKDF2 + SHA-256 + salt individual** antes de ser armazenado.

## Arquitetura

### Frontend

- Cloudflare Pages
- HTML, CSS e JavaScript
- layout **mobile first**
- bolas de 0 a 10 otimizadas para toque em telemóvel

### Backend

Supabase Edge Functions:

- `jogos-api` — contas, autenticação, saldo, levantamentos e administração;
- `jogos-rounds` — abrir/fechar rodadas, receber apostas, sortear e publicar;
- `jogos-messages` — mensagens jogador ↔ administração.

### Banco de dados

Supabase/PostgreSQL armazena, entre outros:

- jogadores;
- rodadas;
- apostas;
- pedidos de saldo;
- pedidos de levantamento;
- sessões administrativas;
- mensagens;
- auditoria.

## Estrutura principal

```text
jogos-lendarios/
├── public/
│   ├── _headers
│   ├── index.html
│   ├── app.js
│   ├── admin.html
│   ├── admin.js
│   ├── enhancements.js
│   ├── styles.css
│   └── mobile.css
├── supabase/
├── package.json
├── server.js
└── README.md
```

## Segurança administrativa

O código real do administrador não deve ser gravado no repositório público. A validação ocorre no backend e as sessões administrativas expiram.

## Implantação atual

O frontend é publicado no Cloudflare Pages a partir da pasta `public`.

Como o projeto Pages atual está usando **Direct Upload**, alterações no GitHub ainda precisam de uma nova implantação manual da pasta `public` até que a integração Git automática seja restabelecida.

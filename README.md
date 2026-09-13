# Jogos Lendários

Primeiro protótipo do projeto **Jogos Lendários**.

## Jogo 1 — Número Lendário (demonstração)

- O jogador escolhe um número inteiro de **0 a 10**.
- A aposta utiliza **créditos virtuais**, sem dinheiro real.
- O sorteio é realmente aleatório usando `crypto.randomInt(0, 11)` do Node.js.
- Quando o número escolhido coincide com o sorteado, o jogador recebe **10× o valor apostado** em créditos virtuais.
- O resultado **não é alterado** conforme o volume apostado em cada número.

> Exemplo promocional da demonstração: **Aposte 10 créditos, ganhe 100 créditos.**

## Administração

O painel administrativo permite:

- autenticação por código configurado no servidor;
- ver jogadores e saldos virtuais;
- aprovar ou rejeitar pedidos de créditos de teste;
- ajustar saldo virtual manualmente;
- bloquear/desbloquear jogadores;
- consultar apostas e resultados recentes;
- consultar totais e estatísticas da demonstração.

### Segurança do código do administrador

O código de administrador **não é gravado no repositório**. Defina-o por variável de ambiente:

```bash
ADMIN_CODE="seu-codigo-aqui" npm start
```

O valor real deve ficar apenas no ambiente de implantação, nunca no GitHub público.

## Executar localmente

Requer Node.js 18+.

```bash
npm start
```

Abra:

- Jogo: `http://localhost:3000`
- Administração: `http://localhost:3000/admin.html`

## Estrutura

```text
jogos-lendarios/
├── public/
│   ├── index.html
│   ├── app.js
│   ├── styles.css
│   ├── admin.html
│   └── admin.js
├── server.js
├── package.json
└── README.md
```

## Importante

Este repositório contém apenas uma **simulação com créditos virtuais**. Não implementa depósitos, levantamentos, transferências, apostas em dinheiro real nem manipulação do sorteio.
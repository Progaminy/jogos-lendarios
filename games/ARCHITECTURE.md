# Arquitectura para muitos jogos

O portal deve continuar leve mesmo quando existirem dezenas ou centenas de jogos.

## Regra principal

A página de entrada é uma shell da plataforma. Ela não deve importar o JavaScript, CSS, imagens pesadas, áudio ou estado de todos os jogos.

Cada jogo novo deve ter uma fronteira própria:

```text
/jogo-x.html
/js/jogo-x/...
/assets/jogo-x/...
```

ou uma rota equivalente que carregue esses recursos apenas quando o jogador entra nesse jogo.

## O que carrega imediatamente

Apenas o núcleo transversal:

- configuração pública;
- RPC base;
- sessão;
- autenticação necessária;
- carteira/apostas da página atualmente aberta;
- acessibilidade;
- navegação.

## O que é sob demanda

- notificações: apenas com sessão ou quando uma notificação precisa ser aberta;
- suporte: no primeiro clique em suporte;
- recuperação de PIN: ao abrir autenticação;
- gestão de sessões: ao abrir a conta autenticada;
- social do Ludo: apenas para jogador autenticado no Ludo;
- animações promocionais: apenas perto da área visível;
- módulos de cada jogo futuro: apenas na rota/entrada desse jogo.

## Renderização

Secções abaixo da dobra usam `content-visibility: auto` para o navegador não gastar layout/pintura em conteúdo distante.

## Regra para jogos futuros

Adicionar um jogo não pode aumentar o bundle inicial de outro jogo. Se um novo jogo acrescentar 500 KB de código, esses 500 KB só podem ser descarregados quando esse jogo for aberto.

Não colocar código de resultados, tabuleiro, áudio, animações ou regras de um jogo futuro dentro de `app.js`, `ludo.js` ou da shell global.

O Service Worker continua sem cache autoritativo de saldo, apostas, partidas ou RPCs financeiras.

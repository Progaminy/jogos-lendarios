# Arquitetura de jogos — ponto 27

A plataforma deve comportar-se como se pudesse ter centenas de jogos.

## Regra principal

Um jogo novo **não adiciona o seu JavaScript ou CSS à página inicial**. Cada jogo pesado fica numa rota própria e declara os seus assets em `games/manifest.json`.

A página inicial mantém apenas:

- shell/navegação/conta;
- Número e Dupla, porque hoje são jogos incorporados;
- metadados leves do catálogo quando forem necessários.

## Carregamento

Assets partilhados opcionais são carregados por `js/platform/feature-loader.js` somente quando necessários. Exemplos: suporte, recuperação de PIN, centro de notificações, sessões/dispositivos e efeitos visuais.

Rotas de jogos podem ser prefetchadas apenas após intenção do utilizador (hover/foco/toque) e nunca quando `Save-Data` estiver ativo ou a ligação for 2G/slow-2G.

## Catálogo futuro

Quando o catálogo crescer:

1. buscar `games/manifest.json` apenas quando o catálogo for aberto/necessário;
2. renderizar em lotes, não centenas de cartões de uma vez;
3. imagens devem ter dimensões explícitas e `loading="lazy"`;
4. usar WebP/AVIF quando existir imagem;
5. filtros/pesquisa trabalham sobre metadados, sem carregar bundles;
6. abrir um jogo carrega somente o bundle daquele jogo.

## Estado financeiro

Nunca pré-carregar nem guardar offline respostas de saldo, aposta, payout ou estado autoritativo. O Service Worker continua dedicado a notificações e sem cache agressivo do estado dos jogos.

## Proteção contra regressão

`tests/frontend/point27-page-weight.test.cjs` falha se módulos opcionais voltarem ao carregamento inicial ou se um bundle de jogo isolado for colocado na home.

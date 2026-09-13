# Jogos Lendários — Cloudflare + Supabase

Arquitetura desta branch:

- GitHub: código-fonte;
- Cloudflare Pages: frontend estático em `public/`;
- Supabase Postgres: persistência;
- Supabase Edge Function `jogos-api`: backend HTTP;
- valores apresentados como **MTS de demonstração**, sem processamento de dinheiro real.

## Supabase

Projeto: `jogos-lendarios`

Project ref:

`bxndjyzghgrmkelshtdp`

Banco criado em `eu-west-1`.

A migration inicial está em:

`supabase/migrations/001_virtual_credits.sql`

O browser não acessa as tabelas diretamente. Todas as tabelas têm RLS ativo e sem políticas públicas. A Edge Function usa a service role interna do Supabase.

A autenticação do admin não grava o código no GitHub. O banco guarda somente o hash do código e as sessões administrativas usam tokens temporários guardados por hash.

## Backend

Edge Function:

`jogos-api`

Base da API:

`https://bxndjyzghgrmkelshtdp.supabase.co/functions/v1/jogos-api`

Health endpoint:

`/api/health`

O frontend em `public/app.js` e `public/admin.js` já aponta para esta API.

## Cloudflare Pages

Criar um projeto Pages a partir de:

`Progaminy/jogos-lendarios`

Configuração:

- Production branch: `cloudflare-supabase`
- Framework preset: None
- Build command: vazio
- Build output directory: `public`
- Root directory: `/`

Não é necessário colocar `SUPABASE_SERVICE_ROLE_KEY`, código administrativo ou outro segredo no Cloudflare. O Cloudflare serve apenas o frontend estático.

O ficheiro `public/_headers` permite chamadas somente ao domínio Supabase necessário, além da própria origem.

## Levantamento em MTS de demonstração

1. O jogador solicita um valor.
2. O pedido nasce `pending`.
3. O valor fica reservado e não pode ser usado em novas apostas ou novos levantamentos.
4. O saldo total ainda não é reduzido.
5. Se o admin aprovar, o banco reduz o saldo numa operação transacional.
6. Se o admin rejeitar, a reserva desaparece e o saldo total permanece igual.

## Sorteio

O sorteio é uniforme entre 0 e 10 e usa Web Crypto no backend. O volume apostado por número não altera o resultado.

## Domínio

Sugestão:

`jogos.adadpsf.shop`

Depois do primeiro deploy no Cloudflare, testar:

- criação de jogador;
- pedido/aprovação de saldo de demonstração;
- aposta;
- pedido de levantamento pendente;
- aprovação e rejeição de levantamento;
- painel administrativo;
- bloqueio/desbloqueio de jogador;
- ajuste administrativo de saldo.

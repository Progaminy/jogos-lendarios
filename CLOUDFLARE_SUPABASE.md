# Jogos Lendários — Cloudflare + Supabase

Esta branch prepara o protótipo para rodar com:

- GitHub como fonte do código;
- Cloudflare Pages para os ficheiros estáticos em `public/`;
- Cloudflare Pages Functions para `/api/*`;
- Supabase Postgres para persistência;
- créditos virtuais apenas.

## 1. Supabase

Recomenda-se um projeto separado chamado `jogos-lendarios`.

Aplicar a migration:

`supabase/migrations/001_virtual_credits.sql`

O browser não acessa as tabelas diretamente. As tabelas têm RLS ativo e as Functions usam uma service role guardada como segredo no Cloudflare.

## 2. Cloudflare Pages

Criar um projeto Pages a partir do repositório:

`Progaminy/jogos-lendarios`

Configuração recomendada:

- Production branch: `cloudflare-supabase`
- Framework preset: None
- Build command: deixar vazio
- Build output directory: `public`
- Root directory: `/`

O diretório `functions/` é detetado automaticamente pelo Cloudflare Pages Functions.

## 3. Variáveis e segredos

No projeto Cloudflare, configurar as seguintes variáveis para Production e Preview:

- `SUPABASE_URL` — URL do projeto Supabase
- `SUPABASE_SERVICE_ROLE_KEY` — segredo server-side do Supabase; nunca colocar no GitHub
- `ADMIN_CODE` — código administrativo; nunca colocar no GitHub
- `ADMIN_TOKEN_SECRET` — segredo aleatório longo para assinar as sessões do admin

Nunca colocar estes valores em ficheiros versionados.

## 4. Fluxo de levantamento de créditos

1. O jogador solicita uma quantidade de créditos.
2. O pedido nasce com estado `pending`.
3. Enquanto está pendente, a quantidade fica reservada e deixa de estar disponível para novas apostas ou novos levantamentos.
4. O saldo total ainda não é reduzido.
5. Se o admin aprovar, a operação é feita numa transação no Postgres e o saldo é reduzido.
6. Se o admin rejeitar, a reserva desaparece e o saldo total permanece igual.

Este mecanismo evita gasto duplo de créditos durante uma aprovação pendente.

## 5. Sorteio

O sorteio continua uniforme entre 0 e 10. A Cloudflare Function gera o número com Web Crypto e rejeição de módulo para evitar viés de distribuição. O volume apostado por número não altera o resultado.

## 6. Domínio

Depois do primeiro deploy estar saudável, adicionar um domínio personalizado no Cloudflare Pages. Exemplo recomendado:

`jogos.adadpsf.shop`

Antes de trocar o domínio público, testar:

- `/api/health`
- criação de jogador
- pedido/aprovação de créditos
- aposta
- pedido de levantamento pendente
- aprovação e rejeição de levantamento
- painel administrativo

# Jogos Lendários

Projeto do jogo **Número Lendário**, com frontend no GitHub, backend e lógica sensível no Supabase e publicação de produção no Cloudflare Workers.

## Estado atual da arquitetura

```text
GitHub (branch main)
        │
        │ fonte oficial do código
        ▼
Cloudflare Workers + Static Assets
        │
        │ publicação automática após push
        ▼
https://jogoslendarios.adadpsf.shop

Supabase
        │
        ├── contas
        ├── sessões
        ├── saldos
        ├── apostas
        ├── depósitos
        ├── saques
        ├── rodadas
        └── lógica real do sorteio
```

### Regra de fonte única

A **branch `main` do GitHub é a fonte oficial do frontend e da configuração do Cloudflare**.

Não editar uma cópia separada do site diretamente no Cloudflare. Toda retificação normal deve seguir:

```text
alterar código
    ↓
testar
    ↓
commit
    ↓
push para main
    ↓
Cloudflare detecta o commit
    ↓
novo build/deploy
    ↓
testar produção
```

O Supabase é a fonte oficial da lógica do banco de dados. Alterações estruturais no banco devem ser feitas como migrations no Supabase.

## Endereços

Produção principal:

```text
https://jogoslendarios.adadpsf.shop
```

URL técnica do Worker:

```text
https://jogos-lendarios.pensadorsemfronteiras0.workers.dev
```

Administração:

```text
https://jogoslendarios.adadpsf.shop/admin.html
```

O endereço `workers.dev` deve ser tratado como endereço técnico. O endereço público principal é `jogoslendarios.adadpsf.shop`.

# Estrutura do projeto

```text
jogos-lendarios/
├── index.html        # interface do jogador
├── styles.css        # aparência do site
├── config.js         # URL e publishable key do Supabase
├── app.js            # comunicação do jogador com o Supabase
├── admin.html        # interface administrativa
├── admin.js          # comunicação do administrador com o Supabase
├── wrangler.jsonc    # configuração do Cloudflare Worker/static assets
├── .assetsignore     # ficheiros que não devem virar assets públicos
├── .gitignore
├── .nojekyll
└── README.md
```

Não existe `server.js` nem backend Node separado. O frontend é HTML/CSS/JavaScript estático. A lógica sensível fica no Supabase.

**Importante:** a lógica que decide o número vencedor NÃO está em `app.js` nem em `admin.js`.

# Jogo: Número Lendário

O jogador escolhe um número inteiro de **0 a 10**, informa o valor e clica em **Apostar**.

Fluxo do jogador:

1. escolhe um número de 0 a 10;
2. informa o valor da aposta;
3. clica em **Apostar**;
4. se ainda não tiver sessão, abre a janela **Criar conta / Já tenho conta**;
5. se for novo jogador, informa nome, telefone, PIN e confirmação do PIN;
6. depois do cadastro/login, a aposta pendente continua automaticamente;
7. o valor é descontado do saldo;
8. o jogador acompanha o cronómetro da rodada;
9. na hora definida pelo administrador, as apostas fecham automaticamente;
10. o Supabase sorteia automaticamente um número;
11. os vencedores são calculados e os prémios são creditados;
12. o resultado é publicado automaticamente para os jogadores.

Quem acertar recebe **10× o valor apostado**.

Se não existir uma rodada aberta, o botão **Apostar** permanece desativado. Isso é comportamento esperado.

# ONDE ESTÁ A LÓGICA DO SORTEIO

A lógica real do sorteio está **no Supabase**, dentro de funções PostgreSQL. Ela não depende do JavaScript do navegador.

```text
admin.html / admin.js
        │
        │ administrador informa a hora
        ▼
Supabase RPC: jl_admin_open_round(...)
        │
        │ grava closes_at
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
        ▼
função: jl_secure_number()
        │
        ▼
número vencedor 0..10
        │
        ├── marca apostas vencedoras
        ├── calcula prémios
        ├── atualiza saldos
        ├── registra transações
        └── publica resultado
```

## `jl_admin_open_round(...)`

Recebe a data/hora definida pelo administrador, valida e cria a rodada.

```text
receber data/hora
        ↓
validar
        ↓
criar rodada
        ↓
grava closes_at
```

Depois disso a hora oficial fica no banco, não no navegador.

## `jl_finalize_due_rounds()`

Finaliza automaticamente rodadas cujo horário já chegou.

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

## `jl_secure_number()`

Gera o número vencedor no banco usando `pgcrypto`.

Números possíveis:

```text
0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
```

Distribuição:

```text
1. gerar um byte criptograficamente aleatório entre 0 e 255
2. aceitar apenas 0..252
3. se cair 253, 254 ou 255, gerar novamente
4. calcular valor % 11
5. resultado fica entre 0 e 10
```

Como:

```text
253 = 23 × 11
```

cada número recebe a mesma quantidade de possibilidades nessa transformação.

O total apostado em cada número **não entra no cálculo**.

# FLUXO COMPLETO DA RODADA

## 1. Administrador define a hora

No `admin.html`, o administrador escolhe a data e hora de encerramento/sorteio.

## 2. Supabase cria a rodada

```text
status     = open
opened_at  = hora de abertura
closes_at  = hora definida
```

## 3. Jogadores apostam

Enquanto:

```text
hora atual < closes_at
```

a rodada aceita apostas.

## 4. Cronómetro chega a zero

O cronómetro do navegador é apenas visual. A regra verdadeira é do banco:

```text
now() >= closes_at
```

Alterar relógio local ou JavaScript não prolonga a rodada.

## 5. Sistema detecta o encerramento

O `pg_cron` chama periodicamente:

```text
jl_finalize_due_rounds()
```

## 6. Apostas fecham

Depois da hora, novas apostas são recusadas pelo banco.

## 7. Número é sorteado

```text
jl_finalize_due_rounds()
        ↓
jl_secure_number()
        ↓
0..10
```

## 8. Vencedores são calculados

```text
selected_number == drawn_number
```

## 9. Prémios

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

O prémio é creditado e a transação fica registrada.

## 11. Resultado é publicado

`app.js` consulta o Supabase e mostra o resultado já decidido pelo banco.

# SORTEIO AUTOMÁTICO

Regra principal:

**o administrador não escolhe o número vencedor depois de ver as apostas.**

Ao abrir uma rodada, o administrador define a hora. O sorteio acontece automaticamente quando a hora chega.

O painel pode ter a ação administrativa de emergência **Encerrar e sortear agora**, mas essa ação apenas antecipa o mesmo processo; não permite escolher o número vencedor nem repetir o sorteio da mesma rodada.

# ADMINISTRAÇÃO

Painel:

```text
/admin.html
```

O administrador pode:

- definir data e hora do sorteio;
- abrir uma rodada;
- acompanhar o tempo restante;
- encerrar e sortear imediatamente em emergência;
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

O PIN não é guardado em texto puro. O banco guarda hash. As sessões usam tokens e o valor original do token não fica armazenado diretamente no banco.

# DEPÓSITOS

```text
jogador pede depósito
        ↓
pedido fica pendente
        ↓
administrador aprova ou rejeita
        ↓
se aprovado, saldo aumenta
```

Nesta fase o sistema não executa automaticamente transferência real por M-Pesa ou banco.

# SAQUES

Saldo insuficiente:

```text
pedido
  ↓
rejeição automática
```

Saldo suficiente:

```text
valor é reservado
        ↓
pedido fica pendente
        ↓
administrador aprova ou rejeita
        ↓
aprovado = valor permanece debitado
rejeitado = valor volta ao saldo
```

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

As tabelas privadas são protegidas. O navegador usa RPCs específicas em vez de acesso irrestrito ao banco.

# COMO CLONAR E RODAR LOCALMENTE

## Primeira vez

```bash
git clone https://github.com/Progaminy/jogos-lendarios.git
cd jogos-lendarios
python3 -m http.server 8080
```

Abrir:

```text
http://localhost:8080
```

Admin local:

```text
http://localhost:8080/admin.html
```

O servidor HTTP local é importante. Evite abrir `index.html` apenas com `file://`, porque o comportamento de alguns recursos do navegador pode ser diferente.

## Se o repositório já foi clonado antes

Antes de começar qualquer retificação:

```bash
cd jogos-lendarios
git status
git switch main
git pull origin main
```

Só começar a alteração depois de garantir que a cópia local está atualizada.

# FLUXO OBRIGATÓRIO DE CADA RETIFICAÇÃO

Cada correção ou melhoria deve seguir esta ordem.

## 1. Atualizar a cópia local

```bash
git switch main
git pull origin main
```

## 2. Fazer a retificação

Alterar somente o necessário para a tarefa atual.

Exemplos:

```text
retificação visual       → index.html / styles.css
retificação de interação → app.js
retificação do admin     → admin.html / admin.js
retificação do banco     → migration no Supabase
retificação de deploy    → wrangler.jsonc / .assetsignore
retificação documental   → README.md
```

## 3. Testar localmente

```bash
python3 -m http.server 8080
```

Testar no navegador:

```text
http://localhost:8080
http://localhost:8080/admin.html
```

Para uma alteração no fluxo de aposta, testar pelo menos:

```text
rodada aberta
→ selecionar número
→ informar valor
→ Apostar
→ cadastro/login
→ aposta pendente continua
```

Para alteração administrativa, testar o fluxo correspondente no painel.

## 4. Conferir exatamente o que mudou

```bash
git status
git diff
```

Não fazer commit de `.env`, senhas, chaves privadas ou ficheiros temporários.

## 5. Fazer um commit claro

```bash
git add .
git commit -m "Corrige fluxo de cadastro após apostar"
```

Cada commit deve descrever a retificação feita. Evitar mensagens genéricas como `update`, `teste` ou `mudancas` quando for possível explicar a alteração.

## 6. Enviar para o GitHub

```bash
git push origin main
```

Esse `push` é o ponto que inicia a publicação automática do frontend em produção.

## 7. Cloudflare recebe o commit

O projeto Cloudflare está ligado ao repositório:

```text
Progaminy/jogos-lendarios
```

Branch de produção:

```text
main
```

O Cloudflare detecta o novo commit, cria um novo build e publica uma nova versão do Worker.

Configuração principal:

```json
{
  "name": "jogos-lendarios",
  "compatibility_date": "2026-09-15",
  "workers_dev": true,
  "assets": {
    "directory": "."
  }
}
```

## 8. Confirmar o deploy

No Cloudflare:

```text
Workers e Pages
→ jogos-lendarios
→ Implantações
```

Confirmar que o commit mais recente apareceu e que a implantação terminou com sucesso.

## 9. Testar produção

Abrir sempre:

```text
https://jogoslendarios.adadpsf.shop
```

E, quando a retificação envolver administração:

```text
https://jogoslendarios.adadpsf.shop/admin.html
```

Não considerar uma retificação concluída apenas porque funcionou localmente. Ela só está concluída depois de conferir a versão em produção.

## 10. Se a produção apresentar problema

Primeiro identificar se o problema está no frontend, banco ou configuração de deploy.

Fluxo recomendado:

```text
problema detectado
      ↓
ver logs/erro
      ↓
identificar commit ou migration responsável
      ↓
corrigir ou reverter
      ↓
novo commit/migration
      ↓
novo teste
      ↓
confirmar produção
```

Não editar aleatoriamente vários ficheiros para tentar resolver sem identificar a causa.

# TIPOS DE RETIFICAÇÃO

## A. Retificação somente no frontend

Exemplos: HTML, CSS, textos, botão, modal, comportamento de JavaScript.

```text
editar localmente
→ testar localmente
→ git diff
→ commit
→ push main
→ Cloudflare publica
→ testar produção
```

Não é necessário alterar o Supabase se o contrato das RPCs continuar igual.

## B. Retificação no Supabase

Exemplos: nova tabela, coluna, índice, função RPC, regra de aposta, lógica de sorteio.

Usar migration para mudanças estruturais.

Fluxo:

```text
entender a alteração
→ aplicar migration no Supabase
→ testar funções/RPCs
→ adaptar frontend se necessário
→ testar localmente
→ commit do código/documentação correspondente
→ push main
→ testar produção completa
```

Mudanças no banco podem afetar produção imediatamente, mesmo antes do próximo deploy do frontend. Por isso devem ser feitas com cuidado.

Nunca colocar no GitHub:

- senha do banco;
- `service_role`;
- chaves privadas;
- tokens administrativos;
- segredos de infraestrutura.

## C. Retificação no Cloudflare

Exemplos: `wrangler.jsonc`, assets, domínio, rota.

Preferir guardar no GitHub toda configuração que puder ser versionada.

```text
alterar configuração no repositório
→ testar
→ commit
→ push main
→ conferir build do Cloudflare
→ testar domínio de produção
```

Alterações de domínio/rota feitas pelo painel do Cloudflare devem ser documentadas no README quando forem permanentes.

## D. Retificação somente no README

```text
editar README.md
→ revisar
→ commit
→ push main
```

Mesmo uma alteração documental gera novo commit e pode aparecer no histórico de builds porque o projeto está ligado à branch `main`.

# COMO COLOCAR ONLINE E EM PRODUÇÃO

## Primeira publicação

A primeira configuração já foi feita:

```text
GitHub:     Progaminy/jogos-lendarios
Branch:     main
Cloudflare: Worker jogos-lendarios
Assets:     raiz do repositório
Domínio:    jogoslendarios.adadpsf.shop
```

Para uma instalação nova em outra conta, o processo conceitual é:

```text
1. criar/importar projeto no Cloudflare
2. conectar o repositório GitHub
3. selecionar a branch main
4. configurar Static Assets
5. usar wrangler.jsonc
6. fazer primeiro deploy
7. habilitar workers.dev para teste técnico
8. conectar domínio personalizado
9. testar frontend e Supabase
```

## Publicações seguintes

Depois da primeira configuração, **não é necessário recriar o projeto nem fazer upload manual de ficheiros**.

Para cada retificação normal:

```bash
git add .
git commit -m "Descrição da retificação"
git push origin main
```

Depois:

```text
GitHub
  ↓
Cloudflare detecta o novo commit
  ↓
Cloudflare faz build/deploy
  ↓
jogoslendarios.adadpsf.shop recebe a nova versão
```

# ROLLBACK / VOLTAR UMA RETIFICAÇÃO

Se um commit causou problema, não apagar o histórico à força.

Preferir:

```bash
git log --oneline
git revert <SHA_DO_COMMIT>
git push origin main
```

O `revert` cria um novo commit que desfaz a alteração e permite ao Cloudflare publicar a versão corrigida mantendo o histórico completo.

Para alterações no Supabase, o rollback deve ser planejado com uma nova migration compatível. Não apagar tabelas ou colunas em produção sem verificar dados e dependências.

# CHECKLIST ANTES DE CONSIDERAR UMA RETIFICAÇÃO CONCLUÍDA

- código atualizado a partir da `main`;
- alteração feita apenas onde necessário;
- teste local realizado;
- `git diff` conferido;
- nenhum segredo adicionado ao GitHub;
- commit com mensagem clara;
- `git push origin main` concluído;
- build do Cloudflare concluído com sucesso;
- domínio `jogoslendarios.adadpsf.shop` testado;
- painel `/admin.html` testado quando aplicável;
- Supabase testado quando a retificação envolve banco/RPC;
- fluxo principal afetado pela alteração testado do início ao fim.

# SUPABASE NO FRONTEND

`config.js` contém somente informações públicas necessárias ao navegador:

- URL pública do projeto;
- publishable key.

A publishable key pode ficar no frontend.

Nunca colocar no GitHub:

- `service_role`;
- senha do banco;
- chaves privadas;
- segredos administrativos.

# REGRA CENTRAL DO PROJETO

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

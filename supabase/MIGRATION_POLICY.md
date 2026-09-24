# Política de migrations do Jogos Lendários

A pasta `supabase/migrations` é o espelho canónico do histórico aplicado no projeto Supabase `bxndjyzghgrmkelshtdp`.

Regras a partir de 24/09/2026:

1. Cada migration usa versão UTC de 14 dígitos: `YYYYMMDDHHMMSS`.
2. Não reutilizar versões nem criar vários ficheiros com o mesmo prefixo temporal.
3. Não editar migrations já aplicadas. Qualquer correção cria uma migration nova e posterior.
4. O estado do repositório deve poder ser reconstruído executando as migrations na ordem lexical.
5. Antes de publicar, comparar esta pasta com `supabase_migrations.schema_migrations`.
6. Alterações que recriem RPCs existentes devem preservar os invariantes de segurança e financeiros consolidados nas migrations posteriores.
7. `regras.md` não faz parte deste mecanismo e não deve ser alterado por tarefas de migrations.

Em 24/09/2026 a pasta foi reconstruída diretamente do histórico real do Supabase: 56 migrations, da versão 20260913074706 até 20260924180524.

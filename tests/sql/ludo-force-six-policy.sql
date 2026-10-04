-- Regressão: o Ludo deve aplicar a mesma regra de 6 forçado a todos os jogadores.
-- Após 6 lançamentos sem 6, a 7ª tentativa força 6. Nenhum UUID pode ter exceção.

begin;

do $$
declare
  def text;
begin
  select pg_get_functiondef(p.oid)
  into def
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.prokind='f'
    and p.proname='jl_ludo_roll'
  limit 1;

  if def is null then
    raise exception 'jl_ludo_roll não encontrada.';
  end if;

  if def !~ 'force_six\s*:=\s*coalesce\(rp\.rolls_without_six,\s*0\)\s*>=\s*6' then
    raise exception 'Regra do 6 forçado não está configurada para a 7ª tentativa.';
  end if;

  if def ~* 'me\s*=\s*''[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}''::uuid' then
    raise exception 'jl_ludo_roll contém privilégio por UUID de jogador.';
  end if;

  if def ~ 'rolls_without_six,\s*0\)\s*>=\s*[0-5]' then
    raise exception 'Encontrado limiar privilegiado de 6 forçado antes da 7ª tentativa.';
  end if;

  if def !~ 'jl_random_index\(6\)' then
    raise exception 'Sorteio normal do dado não usa jl_random_index(6).';
  end if;
end
$$;
rollback;

-- Ludo Lendário: reduzir apenas o limiar global do 6 forçado.
-- Como rolls_without_six conta falhas anteriores, 6 falhas => 6 forçado na 7ª tentativa.
-- Não altera qualquer outra regra, fluxo, jogador privilegiado ou comportamento do Ludo.

do $$
declare
  v_def text;
  v_old text := 'force_six := coalesce(rp.rolls_without_six,0) >= 11;';
  v_new text := 'force_six := coalesce(rp.rolls_without_six,0) >= 6;';
begin
  select pg_get_functiondef('public.jl_ludo_roll(text,uuid)'::regprocedure)
    into v_def;

  if position(v_new in v_def) > 0 then
    return;
  end if;

  if position(v_old in v_def) = 0 then
    raise exception 'Limiar esperado de 6 forçado não encontrado; alteração abortada.';
  end if;

  v_def := replace(v_def, v_old, v_new);
  execute v_def;
end
$$;

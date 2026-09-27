-- Corrige dois problemas de Ludo sem substituir a lógica existente:
-- 1) lugares deixados por jogadores em salas ainda em pré-jogo não podem bloquear novas entradas;
-- 2) um 6 sem jogada legal termina a vez para todos, inclusive quando o 6 foi forçado.
--
-- As duas alterações são cirúrgicas: leem a definição atualmente instalada e
-- apenas inserem/substituem os trechos necessários, preservando regras já ativas.

do $$
declare
  v_def text;
  v_anchor text := '  select x into s';
  v_cleanup text := '  delete from public.ludo_room_players where room_id=p_room and status=''left'';' || E'\n\n  select x into s';
begin
  select pg_get_functiondef('public.jl_ludo_join_room_internal(uuid,uuid)'::regprocedure)
    into v_def;

  if position('delete from public.ludo_room_players where room_id=p_room and status=''left''' in v_def) = 0 then
    if position(v_anchor in v_def) = 0 then
      raise exception 'Trecho esperado de jl_ludo_join_room_internal não encontrado; alteração abortada.';
    end if;

    v_def := replace(v_def, v_anchor, v_cleanup);
    execute v_def;
  end if;
end
$$;

do $$
declare
  v_def text;
  v_old text := 'perform public.jl_ludo_advance_turn(p_room,me,d=6 and (r.rules->>''six_extra_turn'')::boolean);';
  v_new text := 'perform public.jl_ludo_advance_turn(p_room,me,false);';
begin
  select pg_get_functiondef('public.jl_ludo_roll(text,uuid)'::regprocedure)
    into v_def;

  if position(v_new in v_def) = 0 then
    if position(v_old in v_def) = 0 then
      raise exception 'Trecho esperado de jl_ludo_roll não encontrado; alteração abortada.';
    end if;

    v_def := replace(v_def, v_old, v_new);
    execute v_def;
  end if;
end
$$;

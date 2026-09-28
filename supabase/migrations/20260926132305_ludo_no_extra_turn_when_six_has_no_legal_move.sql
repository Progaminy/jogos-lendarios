
do $$
declare
  v_def text;
  v_old text := 'perform public.jl_ludo_advance_turn(p_room,me,d=6 and (r.rules->>''six_extra_turn'')::boolean);';
  v_new text := 'perform public.jl_ludo_advance_turn(p_room,me,false);';
begin
  select pg_get_functiondef('public.jl_ludo_roll(text,uuid)'::regprocedure)
    into v_def;

  if position(v_old in v_def) = 0 then
    raise exception 'Trecho esperado de jl_ludo_roll não encontrado; migração abortada para evitar alterar lógica inesperada.';
  end if;

  v_def := replace(v_def, v_old, v_new);
  execute v_def;
end
$$;

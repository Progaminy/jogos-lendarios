begin;

do $$
declare
  v_def text;
begin
  select pg_get_functiondef('public.jl_aviator_player_state(text)'::regprocedure)
    into v_def;

  if position('limit 20' in lower(v_def))=0 then
    raise exception 'player_state do Aviator deve limitar o conjunto recente';
  end if;

  if position('created_at' in lower(v_def))=0 then
    raise exception 'player_state deve manter janela temporal';
  end if;
end
$$;

rollback;

-- Mantém o helper de posição do Ludo com search_path fixo.
create or replace function public.jl_ludo_global_cell(p_color text, p_steps integer)
returns integer
language sql
immutable
set search_path = public
as $$
  select case
    when p_steps between 0 and 50
      then (public.jl_ludo_color_start(p_color)+p_steps)%52
    else null
  end;
$$;

alter function public.jl_ludo_defaults() set search_path = public;
alter function public.jl_ludo_rules(jsonb,numeric) set search_path = public;
alter function public.jl_ludo_color_start(text) set search_path = public;
alter function public.jl_ludo_global_cell(text,integer) set search_path = public;
alter function public.jl_ludo_is_safe_cell(integer) set search_path = public;

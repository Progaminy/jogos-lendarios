revoke all on function public.jl_player_id(text) from anon, authenticated;
revoke all on function public.jl_admin_ok(text) from anon, authenticated;
revoke all on function public.jl_require_admin(text) from anon, authenticated;
revoke all on function public.jl_secure_number() from anon, authenticated;
revoke all on function public.jl_phone(text) from anon, authenticated;
revoke all on function public.jl_token_hash(text) from anon, authenticated;

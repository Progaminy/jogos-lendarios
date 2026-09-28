
revoke all on function public.jl_notify_ludo_invite() from public, anon, authenticated;
revoke all on function public.jl_notify_support_reply() from public, anon, authenticated;
revoke all on function public.jl_notify_deposit_status() from public, anon, authenticated;
revoke all on function public.jl_notify_withdrawal_status() from public, anon, authenticated;
revoke all on function public.jl_push_after_notification_insert() from public, anon, authenticated;
revoke all on function public.jl_notify_number_win() from public, anon, authenticated;
revoke all on function public.jl_notify_pair_win() from public, anon, authenticated;
revoke all on function public.jl_notify_ludo_payout() from public, anon, authenticated;

-- Ponto 4 da auditoria de segurança:
-- remover grants diretos desnecessários de tabelas internas para anon/authenticated.
-- O acesso da aplicação continua pelas RPCs SECURITY DEFINER já existentes.
-- Nenhuma regra de jogo, cálculo, saldo ou interface é alterada.

revoke all privileges on table public.admin_metric_baselines from anon, authenticated;
revoke all privileges on table public.bonus_grants from anon, authenticated;
revoke all privileges on table public.bonus_usages from anon, authenticated;
revoke all privileges on table public.customer_support_messages from anon, authenticated;
revoke all privileges on table public.deposit_wager_requirements from anon, authenticated;
revoke all privileges on table public.deposit_wager_usages from anon, authenticated;
revoke all privileges on table public.draw_schedule from anon, authenticated;
revoke all privileges on table public.game_settings from anon, authenticated;
revoke all privileges on table public.pair_bets from anon, authenticated;
revoke all privileges on table public.pin_recovery_requests from anon, authenticated;

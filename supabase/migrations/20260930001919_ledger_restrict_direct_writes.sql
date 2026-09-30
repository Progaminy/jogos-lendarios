
revoke insert,update,delete,truncate,references,trigger
on table public.player_financial_ledger
from service_role;

grant select
on table public.player_financial_ledger
to service_role;


revoke insert,update,delete,truncate,references,trigger
on table public.jl_aviator_cashout_guard
from service_role;

grant select
on table public.jl_aviator_cashout_guard
to service_role;

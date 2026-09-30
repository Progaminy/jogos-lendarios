
revoke insert,update,delete,truncate,references,trigger
on table public.jl_api_rate_limits
from service_role;

grant select
on table public.jl_api_rate_limits
to service_role;

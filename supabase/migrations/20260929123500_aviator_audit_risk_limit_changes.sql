-- Aviator: alterações administrativas no limite estrutural de risco
-- (exposure_ratio) são auditadas automaticamente.

create or replace function public.jl_aviator_audit_risk_limit_change()
returns trigger
language plpgsql
set search_path=pg_catalog,public
as $$
declare
  v_admin text:=nullif(current_setting('jl.admin_id',true),'');
  v_session text:=nullif(current_setting('jl.admin_session_id',true),'');
  v_name text:=nullif(current_setting('jl.admin_name',true),'');
  v_role text:=nullif(current_setting('jl.admin_role',true),'');
begin
  if old.exposure_ratio is distinct from new.exposure_ratio
     and v_admin is not null then
    insert into public.audit_log(
      action,
      details,
      actor_admin_id,
      actor_session_id,
      actor_name,
      actor_role,
      target_type,
      target_id,
      before_state,
      after_state
    )
    values(
      'aviator.admin.risk_limit_changed',
      jsonb_build_object(
        'field','exposure_ratio',
        'previous',old.exposure_ratio,
        'current',new.exposure_ratio
      ),
      v_admin::uuid,
      case when v_session is null then null else v_session::uuid end,
      v_name,
      v_role,
      'aviator_bank',
      'global',
      jsonb_build_object(
        'balance',old.balance,
        'exposure_ratio',old.exposure_ratio
      ),
      jsonb_build_object(
        'balance',new.balance,
        'exposure_ratio',new.exposure_ratio
      )
    );
  end if;

  return new;
end
$$;

drop trigger if exists trg_jl_aviator_audit_risk_limit
on public.jl_aviator_bank;

create trigger trg_jl_aviator_audit_risk_limit
after update of exposure_ratio
on public.jl_aviator_bank
for each row
execute function public.jl_aviator_audit_risk_limit_change();

revoke all on function public.jl_aviator_audit_risk_limit_change()
from public,anon,authenticated;
grant execute on function public.jl_aviator_audit_risk_limit_change()
to service_role;

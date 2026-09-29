-- Fix: jl_aviator_admin_close is SECURITY INVOKER and must not read protected
-- Aviator tables directly as anon/authenticated. Use the authorized admin snapshot.

create or replace function public.jl_aviator_admin_close(p_token text)
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare
  v_close jsonb;
  v_resolution jsonb;
  v_state jsonb;
  v_round jsonb;
  v_exposure jsonb;
  v_status text;
  v_active bigint:=0;
begin
  -- Authenticates admin and applies the close atomically inside the
  -- existing SECURITY DEFINER boundary.
  v_close:=public.jl_aviator_admin_set_enabled(p_token,false);
  v_resolution:=coalesce(
    v_close->'resolution',
    jsonb_build_object('action','NONE')
  );

  -- Authorized snapshot. Do not SELECT protected Aviator tables here:
  -- this wrapper intentionally remains SECURITY INVOKER.
  v_state:=public.jl_aviator_admin_state(p_token);
  v_round:=v_state->'round';
  v_exposure:=coalesce(v_state->'exposure','{}'::jsonb);
  v_status:=v_round->>'status';
  v_active:=coalesce((v_exposure->>'active_bets')::bigint,0);

  return jsonb_build_object(
    'ok',true,
    'enabled',false,
    'maintenance_message','Aviator brevemente.',
    'round_id',
      case
        when v_round is null then null
        else (v_round->>'id')::bigint
      end,
    'round_status',v_status,
    'active_bets',v_active,
    'draining',
      coalesce(v_status in ('FLYING','CRASHED'),false)
      and v_active>0,
    'resolution',v_resolution,
    'refunded_bets',
      coalesce((v_resolution->>'refunded_bets')::integer,0),
    'refunded_total',
      coalesce((v_resolution->>'refunded_total')::numeric,0)
  );
end
$$;

revoke all on function public.jl_aviator_admin_close(text)
from public;
grant execute on function public.jl_aviator_admin_close(text)
to anon,authenticated,service_role;

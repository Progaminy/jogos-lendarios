-- Aviator: o painel administrativo recebe o resultado financeiro da drenagem.
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
  v_status text;
  v_active bigint:=0;
begin
  v_close:=public.jl_aviator_admin_set_enabled(p_token,false);
  v_resolution:=coalesce(v_close->'resolution',jsonb_build_object('action','NONE'));

  v_state:=public.jl_aviator_admin_state(p_token);
  v_round:=v_state->'round';
  v_status:=v_round->>'status';

  if v_round is not null then
    select count(*)
      into v_active
    from public.jl_aviator_bets
    where round_id=(v_round->>'id')::bigint
      and status='ACTIVE';
  end if;

  return jsonb_build_object(
    'ok',true,
    'enabled',false,
    'maintenance_message','Aviator brevemente.',
    'round_id',
      case when v_round is null then null else (v_round->>'id')::bigint end,
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

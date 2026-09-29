-- Aviator: operação administrativa dedicada para reabrir com segurança.
-- Nunca reabre enquanto existir rodada transitória/protegida em drenagem.

create or replace function public.jl_aviator_admin_reopen(p_token text)
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare
  v_state jsonb;
  v_round jsonb;
  v_status text;
  v_result jsonb;
begin
  -- Serializa contra apostas e engine durante a decisão de reabertura.
  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));

  -- SECURITY DEFINER existente autentica o token e entrega estado administrativo.
  v_state:=public.jl_aviator_admin_state(p_token);

  if coalesce((v_state->>'enabled')::boolean,false) then
    return jsonb_build_object(
      'ok',true,
      'enabled',true,
      'already_open',true,
      'maintenance_message','Aviator brevemente.'
    );
  end if;

  v_round:=v_state->'round';
  v_status:=v_round->>'status';

  if coalesce(v_status in ('OPEN','LOCKED','FLYING','CRASHED'),false) then
    raise exception 'Aguarde a rodada atual terminar antes de reabrir o Aviator.';
  end if;

  -- A função existente também limpa one_round_test e grava auditoria.
  v_result:=public.jl_aviator_admin_set_enabled(p_token,true);

  return jsonb_build_object(
    'ok',true,
    'enabled',true,
    'already_open',false,
    'maintenance_message','Aviator brevemente.',
    'ready_for_new_rounds',true
  );
end
$$;

revoke all on function public.jl_aviator_admin_reopen(text)
from public;
grant execute on function public.jl_aviator_admin_reopen(text)
to anon,authenticated,service_role;

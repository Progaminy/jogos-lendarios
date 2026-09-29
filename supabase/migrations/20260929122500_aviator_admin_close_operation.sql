-- Aviator: operação administrativa dedicada para fechar por manutenção.
-- O fecho reutiliza a transação/lock de manutenção existente e nunca reabre o jogo.

update public.jl_aviator_settings
   set maintenance_message='Aviator brevemente.',
       updated_at=clock_timestamp()
 where id=true
   and maintenance_message is distinct from 'Aviator brevemente.';

create or replace function public.jl_aviator_admin_close(p_token text)
returns jsonb
language plpgsql
security invoker
set search_path=pg_catalog,public
as $$
declare
  v_close jsonb;
  v_state jsonb;
  v_round jsonb;
  v_status text;
  v_active bigint:=0;
begin
  -- jl_aviator_admin_set_enabled(false) autentica o admin e toma
  -- o lock exclusivo jl_aviator_maintenance. Apostas novas usam
  -- lock compartilhado, logo nenhuma passa depois deste commit.
  v_close:=public.jl_aviator_admin_set_enabled(p_token,false);
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
    'empty_open_rounds_cancelled',
      coalesce((v_close->>'empty_open_rounds_cancelled')::bigint,0),
    'round_id',
      case when v_round is null then null else (v_round->>'id')::bigint end,
    'round_status',v_status,
    'active_bets',v_active,
    'draining',
      coalesce(v_status in ('OPEN','LOCKED','FLYING','CRASHED'),false)
      and v_active>0
  );
end
$$;

revoke all on function public.jl_aviator_admin_close(text)
from public;
grant execute on function public.jl_aviator_admin_close(text)
to anon,authenticated,service_role;

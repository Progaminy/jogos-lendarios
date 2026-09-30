create or replace function public.jl_aviator_reconnect_rate_limit(p_token text)
returns void
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_player uuid:=public.jl_player_id(p_token);
begin
  perform public.jl_rate_limit_enforce(
    'aviator_reconnect',
    v_player::text,
    20,10,120,60
  );
end;
$function$;

revoke all on function public.jl_aviator_reconnect_rate_limit(text)
from public;

grant execute on function public.jl_aviator_reconnect_rate_limit(text)
to anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.jl_aviator_reconnect(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_public jsonb;
  v_player jsonb;
begin
  perform public.jl_aviator_reconnect_rate_limit(p_token);

  -- O engine usa o mesmo advisory lock em modo exclusivo.
  -- Durante esta leitura ele nao pode mudar OPEN/LOCKED/FLYING/CRASHED/SETTLED.
  perform pg_advisory_xact_lock_shared(
    hashtext('jl_aviator_engine_tick')
  );

  v_public:=public.jl_aviator_public_state();
  v_player:=public.jl_aviator_player_state(p_token);

  return jsonb_build_object(
    'server_time',v_public->'server_time',
    'display_at',v_public->'display_at',
    'display_seq',v_public->'display_seq',
    'display_frame_ms',v_public->'display_frame_ms',
    'enabled',v_public->'enabled',
    'maintenance_message',v_public->'maintenance_message',
    'round',v_public->'round',
    'player',v_player
  );
end
$function$;
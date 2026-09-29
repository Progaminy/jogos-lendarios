-- Aviator: reconexao coerente sem reconstruir o voo no navegador.
-- Um unico RPC devolve estado publico autoritativo + estado financeiro do jogador.
-- O lock compartilhado do engine impede transicao do motor no meio do snapshot.

create or replace function public.jl_aviator_reconnect(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  v_public jsonb;
  v_player jsonb;
begin
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
$$;

revoke all on function public.jl_aviator_reconnect(text) from public;
grant execute on function public.jl_aviator_reconnect(text)
to anon,authenticated,service_role;

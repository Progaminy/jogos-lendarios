create or replace function public.jl_dama_analysis_context(p_token text,p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_access jsonb;
  v_enabled boolean:=false;
  v_reason text:='NOT_ALLOWED';
  v_next uuid;
  v_positions jsonb:='{}'::jsonb;
  v_current_key text;
begin
  v_access:=public.jl_dama_analysis_access(p_token,p_room);
  v_enabled:=coalesce((v_access->>'enabled')::boolean,false);
  v_reason:=coalesce(v_access->>'reason','NOT_ALLOWED');

  if not v_enabled then
    return jsonb_build_object(
      'enabled',false,
      'reason',v_reason,
      'positions','{}'::jsonb,
      'current_key',null
    );
  end if;

  select current_player_id into v_next
  from public.dama_rooms
  where id=p_room;

  select coalesce(jsonb_object_agg(position_key,occurrences),'{}'::jsonb)
  into v_positions
  from public.dama_positions
  where room_id=p_room;

  if v_next is not null then
    v_current_key:=public.jl_dama_position_key(p_room,v_next);
  end if;

  return jsonb_build_object(
    'enabled',true,
    'reason','OK',
    'positions',v_positions,
    'current_key',v_current_key
  );
end;
$$;

revoke all on function public.jl_dama_analysis_context(text,uuid) from public,anon,authenticated;
grant execute on function public.jl_dama_analysis_context(text,uuid) to anon,authenticated;

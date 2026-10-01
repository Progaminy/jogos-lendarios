-- Ludo Realtime: publish the public dice result with the room sync signal.
-- Other room state remains fetched through the authoritative RPC snapshot.

create or replace function public.jl_ludo_realtime_broadcast_sync()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_room uuid;
  v_kind text;
  v_seq text;
  v_row jsonb:=to_jsonb(new);
  v_message jsonb;
begin
  v_room := (v_row->>'room_id')::uuid;
  v_seq := v_row->>'id';
  v_kind := case
    when tg_table_name='ludo_events' then coalesce(v_row->>'event_type','event')
    when tg_table_name='ludo_chat' then 'chat'
    else 'sync'
  end;

  if v_room is not null then
    v_message:=jsonb_build_object(
      'room_id',v_room,
      'kind',v_kind,
      'seq',v_seq
    );

    if tg_table_name='ludo_events' and v_kind='dice_rolled' then
      v_message:=v_message||jsonb_build_object(
        'player_id',v_row->>'player_id',
        'dice',v_row->'payload'->'dice',
        'dice_values',v_row->'payload'->'dice_values'
      );
    end if;

    perform realtime.send(
      v_message,
      'sync',
      'ludo:room:'||v_room::text,
      false
    );
  end if;

  return null;
end;
$function$;

revoke all on function public.jl_ludo_realtime_broadcast_sync()
from public,anon,authenticated;

grant execute on function public.jl_ludo_realtime_broadcast_sync()
to service_role;

-- Ludo Realtime: publica apenas um sinal mínimo por sala.
-- O cliente usa o sinal para buscar novamente o estado autoritativo pelas RPCs
-- existentes; nenhum estado privado da partida é enviado pelo Broadcast.

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
begin
  v_room := (to_jsonb(new)->>'room_id')::uuid;
  v_seq := to_jsonb(new)->>'id';
  v_kind := case
    when tg_table_name='ludo_events' then coalesce(to_jsonb(new)->>'event_type','event')
    when tg_table_name='ludo_chat' then 'chat'
    else 'sync'
  end;

  if v_room is not null then
    perform realtime.send(
      jsonb_build_object(
        'room_id',v_room,
        'kind',v_kind,
        'seq',v_seq
      ),
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

drop trigger if exists jl_ludo_events_realtime_sync
on public.ludo_events;

create trigger jl_ludo_events_realtime_sync
after insert on public.ludo_events
for each row
execute function public.jl_ludo_realtime_broadcast_sync();

drop trigger if exists jl_ludo_chat_realtime_sync
on public.ludo_chat;

create trigger jl_ludo_chat_realtime_sync
after insert on public.ludo_chat
for each row
execute function public.jl_ludo_realtime_broadcast_sync();

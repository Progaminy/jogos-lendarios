-- Player sessions: last successful login wins.
-- Concurrent logins are serialized on the player row. The newest successful
-- login revokes any previous session before its own session is inserted.

create or replace function public.jl_guard_single_player_session()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
begin
  perform 1
  from public.players
  where id = new.player_id
  for update;

  delete from public.player_sessions
  where player_id = new.player_id;

  return new;
end;
$function$;

revoke all on function public.jl_guard_single_player_session()
from public, anon, authenticated;

comment on function public.jl_guard_single_player_session()
is 'Serializes player logins and enforces last-login-wins by revoking the previous session before insert.';

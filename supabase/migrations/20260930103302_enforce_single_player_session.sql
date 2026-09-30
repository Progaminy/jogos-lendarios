-- Enforce exactly one persisted player session per player.
-- Expired sessions are removed on the next login attempt; duplicate live sessions
-- are collapsed to the most recently seen one during this migration.

delete from public.player_sessions
where expires_at<=now();

with ranked as (
  select
    id,
    row_number() over (
      partition by player_id
      order by last_seen_at desc, created_at desc, id desc
    ) as rn
  from public.player_sessions
)
delete from public.player_sessions s
using ranked r
where s.id=r.id
  and r.rn>1;

create unique index if not exists player_sessions_single_player_uq
  on public.player_sessions(player_id);

create or replace function public.jl_guard_single_player_session()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
begin
  perform 1
  from public.players
  where id=new.player_id
  for update;

  delete from public.player_sessions
  where player_id=new.player_id
    and expires_at<=now();

  if exists (
    select 1
    from public.player_sessions
    where player_id=new.player_id
      and expires_at>now()
  ) then
    raise exception using
      errcode='P0001',
      message='Esta conta já está ligada noutro dispositivo.';
  end if;

  return new;
end;
$function$;

revoke all on function public.jl_guard_single_player_session() from public, anon, authenticated;

drop trigger if exists player_sessions_single_session_guard
  on public.player_sessions;

create trigger player_sessions_single_session_guard
before insert on public.player_sessions
for each row
execute function public.jl_guard_single_player_session();

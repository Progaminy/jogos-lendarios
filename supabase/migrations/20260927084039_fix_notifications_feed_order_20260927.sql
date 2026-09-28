
create or replace function public.jl_notifications_feed(
  p_token text,
  p_limit integer default 80
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  me uuid := public.jl_player_id(p_token);
  lim integer := greatest(1,least(coalesce(p_limit,80),100));
  rows jsonb;
begin
  update public.player_sessions
  set last_seen_at=now()
  where token_hash=public.jl_token_hash(p_token)
    and expires_at>now();

  select coalesce(jsonb_agg(x order by x."createdAt" desc),'[]'::jsonb)
  into rows
  from (
    select
      coalesce(n.source_key,'server:'||n.id::text) as id,
      n.id as "serverId",
      n.kind as type,
      n.title,
      n.message,
      n.href,
      n.created_at as "createdAt",
      (n.read_at is not null) as read,
      true as "serverBacked"
    from public.player_notifications n
    where n.player_id=me
      and n.dismissed_at is null
    order by n.created_at desc
    limit lim
  ) x;

  return rows;
end;
$$;

grant execute on function public.jl_notifications_feed(text,integer) to anon, authenticated;

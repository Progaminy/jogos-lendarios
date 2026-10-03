create or replace function public.jl_social_online_players(
  p_token text,
  p_limit integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := public.jl_player_id(p_token);
  lim integer := greatest(1, least(coalesce(p_limit, 100), 200));
  rows jsonb;
  online_total integer;
begin
  update public.player_sessions
  set last_seen_at = now()
  where token_hash = public.jl_token_hash(p_token)
    and expires_at > now();

  select count(distinct s.player_id)
  into online_total
  from public.player_sessions s
  join public.players p on p.id = s.player_id
  where s.expires_at > now()
    and s.last_seen_at >= now() - interval '20 seconds'
    and not p.blocked
    and p.deleted_at is null;

  with live as (
    select
      p.id,
      p.name,
      max(s.last_seen_at) as last_seen_at
    from public.player_sessions s
    join public.players p on p.id = s.player_id
    where s.expires_at > now()
      and s.last_seen_at >= now() - interval '20 seconds'
      and p.id <> me
      and not p.blocked
      and p.deleted_at is null
    group by p.id, p.name
    order by max(s.last_seen_at) desc, p.name, p.id
    limit lim
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'player_id', x.id,
        'name', x.name,
        'code', public.jl_ludo_display_code(x.id),
        'online', true,
        'following', exists(
          select 1
          from public.player_follows f
          where f.follower_id = me and f.followed_id = x.id
        ),
        'follows_you', exists(
          select 1
          from public.player_follows f
          where f.follower_id = x.id and f.followed_id = me
        ),
        'in_game', exists(
          select 1
          from public.ludo_room_players rp
          join public.ludo_rooms r on r.id = rp.room_id
          where rp.player_id = x.id
            and rp.status <> 'left'
            and r.status in ('waiting','negotiating','funding','playing')
        )
      )
      order by x.last_seen_at desc, x.name, x.id
    ),
    '[]'::jsonb
  )
  into rows
  from live x;

  return jsonb_build_object(
    'players', rows,
    'online_count', online_total
  );
end;
$$;

revoke all on function public.jl_social_online_players(text, integer)
from public, anon, authenticated;

grant execute on function public.jl_social_online_players(text, integer)
to anon, authenticated;

comment on function public.jl_social_online_players(text, integer) is
  'Lista jogadores realmente online para o Ludo. Exige token de jogador válido e expõe somente identidade pública social.';

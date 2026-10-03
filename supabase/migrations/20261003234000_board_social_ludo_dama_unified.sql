-- Social dos Jogos Lendários passa a ser do Tabuleiro, não exclusivo do Ludo.
-- "Em jogo" considera Ludo OU Dama e notificações de seguidores abrem o Tabuleiro.

create or replace function public.jl_social_list(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid := public.jl_player_id(p_token);
  rows jsonb;
  following_total integer;
  followers_total integer;
  online_total integer;
begin
  update public.player_sessions
  set last_seen_at=now()
  where token_hash=public.jl_token_hash(p_token)
    and expires_at>now();

  insert into public.ludo_player_codes(player_id)
  select p.id
  from public.players p
  where not p.blocked
    and p.deleted_at is null
    and not exists(
      select 1 from public.ludo_player_codes c where c.player_id=p.id
    )
  order by p.created_at,p.id
  on conflict(player_id) do nothing;

  select count(*) into following_total
  from public.player_follows
  where follower_id=me;

  select count(*) into followers_total
  from public.player_follows
  where followed_id=me;

  select count(*) into online_total
  from public.player_follows f
  where f.follower_id=me
    and exists(
      select 1
      from public.player_sessions s
      where s.player_id=f.followed_id
        and s.expires_at>now()
        and s.last_seen_at>=now()-interval '25 seconds'
    );

  select coalesce(jsonb_agg(x order by x.online desc,x.name,x.code),'[]'::jsonb)
  into rows
  from (
    select
      p.id as player_id,
      p.name,
      public.jl_ludo_display_code(p.id) as code,
      exists(
        select 1 from public.player_sessions s
        where s.player_id=p.id
          and s.expires_at>now()
          and s.last_seen_at>=now()-interval '25 seconds'
      ) as online,
      (
        exists(
          select 1
          from public.ludo_room_players rp
          join public.ludo_rooms r on r.id=rp.room_id
          where rp.player_id=p.id
            and rp.status<>'left'
            and r.status in ('waiting','negotiating','funding','playing')
        )
        or exists(
          select 1
          from public.dama_room_players dp
          join public.dama_rooms d on d.id=dp.room_id
          where dp.player_id=p.id
            and dp.status<>'left'
            and d.status in ('waiting','negotiating','funding','ready','playing')
        )
      ) as in_game,
      exists(
        select 1 from public.player_follows back
        where back.follower_id=p.id and back.followed_id=me
      ) as mutual,
      f.created_at as followed_at
    from public.player_follows f
    join public.players p on p.id=f.followed_id
    where f.follower_id=me
      and not p.blocked
      and p.deleted_at is null
  ) x;

  return jsonb_build_object(
    'following',rows,
    'following_count',following_total,
    'followers_count',followers_total,
    'online_count',online_total
  );
end;
$$;

create or replace function public.jl_social_find_players(
  p_token text,
  p_query text default ''
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid := public.jl_player_id(p_token);
  q text := trim(coalesce(p_query,''));
begin
  insert into public.ludo_player_codes(player_id)
  select p.id
  from public.players p
  where not p.blocked
    and p.deleted_at is null
    and not exists(
      select 1 from public.ludo_player_codes c where c.player_id=p.id
    )
  order by p.created_at,p.id
  on conflict(player_id) do nothing;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'player_id',x.id,
      'name',x.name,
      'code',public.jl_ludo_display_code(x.id),
      'following',exists(
        select 1 from public.player_follows f
        where f.follower_id=me and f.followed_id=x.id
      ),
      'follows_you',exists(
        select 1 from public.player_follows f
        where f.follower_id=x.id and f.followed_id=me
      ),
      'online',exists(
        select 1 from public.player_sessions s
        where s.player_id=x.id
          and s.expires_at>now()
          and s.last_seen_at>=now()-interval '25 seconds'
      ),
      'in_game',(
        exists(
          select 1
          from public.ludo_room_players rp
          join public.ludo_rooms r on r.id=rp.room_id
          where rp.player_id=x.id
            and rp.status<>'left'
            and r.status in ('waiting','negotiating','funding','playing')
        )
        or exists(
          select 1
          from public.dama_room_players dp
          join public.dama_rooms d on d.id=dp.room_id
          where dp.player_id=x.id
            and dp.status<>'left'
            and d.status in ('waiting','negotiating','funding','ready','playing')
        )
      )
    ) order by x.name,public.jl_ludo_display_code(x.id))
    from (
      select p.id,p.name
      from public.players p
      where p.id<>me
        and not p.blocked
        and p.deleted_at is null
        and (
          q=''
          or p.name ilike '%'||q||'%'
          or public.jl_ludo_display_code(p.id) ilike '%'||q||'%'
        )
      order by p.name,p.created_at
      limit 40
    ) x
  ),'[]'::jsonb);
end;
$$;

create or replace function public.jl_social_online_players(
  p_token text,
  p_limit integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid := public.jl_player_id(p_token);
  lim integer := greatest(1,least(coalesce(p_limit,100),200));
  rows jsonb;
  online_total integer;
begin
  update public.player_sessions
  set last_seen_at=now()
  where token_hash=public.jl_token_hash(p_token)
    and expires_at>now();

  select count(distinct s.player_id)
  into online_total
  from public.player_sessions s
  join public.players p on p.id=s.player_id
  where s.expires_at>now()
    and s.last_seen_at>=now()-interval '20 seconds'
    and not p.blocked
    and p.deleted_at is null;

  with live as (
    select
      p.id,
      p.name,
      max(s.last_seen_at) as last_seen_at
    from public.player_sessions s
    join public.players p on p.id=s.player_id
    where s.expires_at>now()
      and s.last_seen_at>=now()-interval '20 seconds'
      and not p.blocked
      and p.deleted_at is null
    group by p.id,p.name
    order by max(s.last_seen_at) desc,p.name,p.id
    limit lim
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'player_id',x.id,
        'name',x.name,
        'code',public.jl_ludo_display_code(x.id),
        'online',true,
        'is_self',x.id=me,
        'following',exists(
          select 1 from public.player_follows f
          where f.follower_id=me and f.followed_id=x.id
        ),
        'follows_you',exists(
          select 1 from public.player_follows f
          where f.follower_id=x.id and f.followed_id=me
        ),
        'in_game',(
          exists(
            select 1
            from public.ludo_room_players rp
            join public.ludo_rooms r on r.id=rp.room_id
            where rp.player_id=x.id
              and rp.status<>'left'
              and r.status in ('waiting','negotiating','funding','playing')
          )
          or exists(
            select 1
            from public.dama_room_players dp
            join public.dama_rooms d on d.id=dp.room_id
            where dp.player_id=x.id
              and dp.status<>'left'
              and d.status in ('waiting','negotiating','funding','ready','playing')
          )
        )
      )
      order by x.last_seen_at desc,x.name,x.id
    ),
    '[]'::jsonb
  )
  into rows
  from live x;

  return jsonb_build_object(
    'players',rows,
    'online_count',online_total
  );
end;
$$;

create or replace function public.jl_social_follow(
  p_token text,
  p_target_player uuid,
  p_follow boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid := public.jl_player_id(p_token);
  actor_name text;
  actor_code text;
  is_mutual boolean := false;
  inserted_count integer := 0;
begin
  if p_target_player is null or p_target_player=me then
    raise exception 'Jogador inválido.';
  end if;

  if not exists(
    select 1 from public.players
    where id=p_target_player and not blocked and deleted_at is null
  ) then
    raise exception 'Jogador não encontrado.';
  end if;

  if coalesce(p_follow,true) then
    insert into public.player_follows(follower_id,followed_id)
    values(me,p_target_player)
    on conflict do nothing;
    get diagnostics inserted_count=row_count;

    if inserted_count>0 then
      select name into actor_name from public.players where id=me;
      perform public.jl_ludo_ensure_code(me);
      actor_code:=public.jl_ludo_display_code(me);

      perform public.jl_notification_create(
        p_target_player,
        'follow',
        actor_name||' começou a seguir você',
        actor_code||' adicionou você à lista de jogadores acompanhados.',
        './tabuleiro.html#boardSocial',
        null
      );
    end if;
  else
    delete from public.player_follows
    where follower_id=me and followed_id=p_target_player;
  end if;

  select exists(
    select 1 from public.player_follows
    where follower_id=p_target_player and followed_id=me
  ) into is_mutual;

  return jsonb_build_object(
    'ok',true,
    'following',coalesce(p_follow,true),
    'mutual',is_mutual
  );
end;
$$;

revoke all on function public.jl_social_list(text) from public,anon,authenticated;
revoke all on function public.jl_social_find_players(text,text) from public,anon,authenticated;
revoke all on function public.jl_social_online_players(text,integer) from public,anon,authenticated;
revoke all on function public.jl_social_follow(text,uuid,boolean) from public,anon,authenticated;

grant execute on function public.jl_social_list(text) to anon,authenticated;
grant execute on function public.jl_social_find_players(text,text) to anon,authenticated;
grant execute on function public.jl_social_online_players(text,integer) to anon,authenticated;
grant execute on function public.jl_social_follow(text,uuid,boolean) to anon,authenticated;

comment on function public.jl_social_online_players(text,integer) is
  'Lista jogadores realmente online para o Tabuleiro dos Jogos Lendários; em jogo considera Ludo e Dama.';

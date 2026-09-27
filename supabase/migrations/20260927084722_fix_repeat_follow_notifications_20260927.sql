create or replace function public.jl_social_follow(
  p_token text,
  p_target_player uuid,
  p_follow boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
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
        './ludo.html#socialZone',
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

grant execute on function public.jl_social_follow(text,uuid,boolean) to anon, authenticated;

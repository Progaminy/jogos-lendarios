-- Ponto 16 — evitar regravar a mesma subscrição push em ciclos da mesma sessão.
-- Mantém endpoint único, push separado das notificações internas e CORS da Edge Function.

create or replace function public.jl_push_subscribe(
  p_token text,
  p_endpoint text,
  p_p256dh text,
  p_auth text,
  p_user_agent text default ''
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  me uuid := public.jl_player_id(p_token);
  v_id uuid;
  v_endpoint text := left(coalesce(p_endpoint,''),2048);
  v_p256dh text := left(coalesce(p_p256dh,''),500);
  v_auth text := left(coalesce(p_auth,''),500);
  v_user_agent text := left(coalesce(p_user_agent,''),300);
begin
  if v_endpoint='' or length(v_endpoint) not between 20 and 2048 or v_endpoint !~ '^https://' then
    raise exception 'Subscrição push inválida.';
  end if;

  if length(v_p256dh)<20 or length(v_auth)<8 then
    raise exception 'Chaves push inválidas.';
  end if;

  select s.id
  into v_id
  from public.player_push_subscriptions s
  where s.endpoint=v_endpoint
    and s.player_id=me
    and s.p256dh=v_p256dh
    and s.auth=v_auth
    and coalesce(s.user_agent,'')=v_user_agent
    and s.disabled_at is null
  limit 1;

  if v_id is not null then
    return jsonb_build_object(
      'ok',true,
      'subscription_id',v_id,
      'reused',true
    );
  end if;

  insert into public.player_push_subscriptions(
    player_id,endpoint,p256dh,auth,user_agent,updated_at,disabled_at
  )
  values(
    me,v_endpoint,v_p256dh,v_auth,v_user_agent,now(),null
  )
  on conflict(endpoint) do update set
    player_id=excluded.player_id,
    p256dh=excluded.p256dh,
    auth=excluded.auth,
    user_agent=excluded.user_agent,
    updated_at=now(),
    disabled_at=null
  returning id into v_id;

  return jsonb_build_object(
    'ok',true,
    'subscription_id',v_id,
    'reused',false
  );
end;
$function$;

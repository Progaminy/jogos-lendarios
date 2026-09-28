-- Ponto 19 — sessões no navegador.
-- Jogador: persistência mantida, com lista/revogação/rotação.
-- Admin: a mudança para sessionStorage é feita no frontend; o backend continua
-- com sessão administrativa de 12 horas.
-- Nenhuma chave service_role é exposta ao navegador.

alter table public.player_sessions
  add column if not exists ip_address text,
  add column if not exists user_agent text,
  add column if not exists rotated_at timestamptz;

update public.player_sessions
set rotated_at=coalesce(rotated_at,created_at)
where rotated_at is null;

alter table public.player_sessions
  alter column rotated_at set default now(),
  alter column rotated_at set not null;

create index if not exists player_sessions_player_expiry_idx
  on public.player_sessions(player_id,expires_at desc);

create or replace function public.jl_player_id(p_token text)
returns uuid
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_id uuid;
  v_session_id uuid;
begin
  select id,player_id
  into v_session_id,v_id
  from public.player_sessions
  where token_hash=public.jl_token_hash(p_token)
    and expires_at>now()
  limit 1;

  if v_id is null then
    raise exception 'Sessão do jogador inválida ou expirada.';
  end if;

  update public.player_sessions
  set last_seen_at=now()
  where id=v_session_id
    and last_seen_at<now()-interval '5 minutes';

  return v_id;
end;
$function$;

create or replace function public.jl_login_player(p_phone text,p_pin text)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_phone text := public.jl_phone(p_phone);
  v_player public.players%rowtype;
  v_token text;
  v_headers jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  v_ip text;
  v_agent text;
  v_source text;
  v_key text;
  v_rate public.login_rate_limits%rowtype;
  v_failed integer;
  v_level integer;
  v_minutes integer;
  v_retry integer;
begin
  v_ip := nullif(btrim(split_part(coalesce(v_headers->>'x-forwarded-for',''), ',', 1)), '');
  if v_ip is null then v_ip := nullif(v_headers->>'cf-connecting-ip',''); end if;
  if v_ip is null then v_ip := nullif(v_headers->>'x-real-ip',''); end if;
  v_agent := nullif(left(coalesce(v_headers->>'user-agent',''),300),'');
  v_source := coalesce(v_ip,v_agent,'unknown');
  v_key := encode(extensions.digest(v_phone || '|' || v_source,'sha256'),'hex');

  insert into public.login_rate_limits(scope,subject_key)
  values('player',v_key)
  on conflict(scope,subject_key) do nothing;

  select * into v_rate
  from public.login_rate_limits
  where scope='player' and subject_key=v_key
  for update;

  if v_rate.last_failed_at is not null
     and v_rate.last_failed_at<now()-interval '24 hours'
     and coalesce(v_rate.blocked_until,'-infinity'::timestamptz)<=now() then
    update public.login_rate_limits
    set failed_attempts=0,block_level=0,blocked_until=null,updated_at=now()
    where scope='player' and subject_key=v_key;
    v_rate.failed_attempts:=0;
    v_rate.block_level:=0;
    v_rate.blocked_until:=null;
  end if;

  if v_rate.blocked_until is not null and v_rate.blocked_until>now() then
    v_retry:=greatest(1,ceil(extract(epoch from (v_rate.blocked_until-now()))/60.0)::integer);
    perform set_config('response.status','429',true);
    return jsonb_build_object(
      'ok',false,
      'message',format('Muitas tentativas. Tente novamente em %s minuto(s).',v_retry),
      'retry_after_minutes',v_retry
    );
  end if;

  select * into v_player
  from public.players
  where phone=v_phone
  limit 1;

  if v_player.id is null
     or extensions.crypt(coalesce(p_pin,''),v_player.pin_hash)<>v_player.pin_hash then
    v_failed:=coalesce(v_rate.failed_attempts,0)+1;

    if v_failed>=5 then
      v_level:=coalesce(v_rate.block_level,0)+1;
      v_minutes:=case v_level
        when 1 then 5
        when 2 then 15
        when 3 then 30
        when 4 then 60
        when 5 then 120
        when 6 then 240
        when 7 then 480
        when 8 then 960
        else 1440
      end;

      update public.login_rate_limits
      set failed_attempts=0,
          block_level=v_level,
          blocked_until=now()+make_interval(mins=>v_minutes),
          last_failed_at=now(),
          updated_at=now()
      where scope='player' and subject_key=v_key;

      perform set_config('response.status','429',true);
      return jsonb_build_object(
        'ok',false,
        'message',format('Muitas tentativas. Tente novamente em %s minuto(s).',v_minutes),
        'retry_after_minutes',v_minutes
      );
    end if;

    update public.login_rate_limits
    set failed_attempts=v_failed,last_failed_at=now(),updated_at=now()
    where scope='player' and subject_key=v_key;

    perform set_config('response.status','401',true);
    return jsonb_build_object(
      'ok',false,
      'message','Telefone ou PIN incorreto.',
      'attempts_remaining',5-v_failed
    );
  end if;

  if v_player.blocked then
    perform set_config('response.status','403',true);
    return jsonb_build_object('ok',false,'message','Esta conta está bloqueada.');
  end if;

  delete from public.login_rate_limits
  where scope='player' and subject_key=v_key;

  v_token:=encode(extensions.gen_random_bytes(32),'hex');

  insert into public.player_sessions(
    player_id,token_hash,expires_at,last_seen_at,rotated_at,ip_address,user_agent
  ) values(
    v_player.id,
    public.jl_token_hash(v_token),
    now()+interval '30 days',
    now(),
    now(),
    v_ip,
    v_agent
  );

  return jsonb_build_object(
    'ok',true,
    'token',v_token,
    'player',jsonb_build_object(
      'id',v_player.id,
      'name',v_player.name,
      'phone',v_player.phone,
      'balance',v_player.balance,
      'blocked',v_player.blocked
    )
  );
end;
$function$;

create or replace function public.jl_player_sessions(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  me uuid:=public.jl_player_id(p_token);
  current_hash text:=public.jl_token_hash(p_token);
  rows jsonb;
begin
  select coalesce(jsonb_agg(x order by x.is_current desc,x.last_seen_at desc),'[]'::jsonb)
  into rows
  from (
    select
      s.id as session_id,
      (s.token_hash=current_hash) as is_current,
      s.created_at,
      s.last_seen_at,
      s.expires_at,
      s.rotated_at,
      coalesce(s.user_agent,'Dispositivo não identificado') as user_agent
    from public.player_sessions s
    where s.player_id=me
      and s.expires_at>now()
  ) x;

  return rows;
end;
$function$;

create or replace function public.jl_player_revoke_session(
  p_token text,
  p_session_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  me uuid:=public.jl_player_id(p_token);
  current_hash text:=public.jl_token_hash(p_token);
  removed_hash text;
begin
  delete from public.player_sessions
  where id=p_session_id
    and player_id=me
  returning token_hash into removed_hash;

  if removed_hash is null then
    raise exception 'Sessão não encontrada.';
  end if;

  return jsonb_build_object(
    'ok',true,
    'current_ended',removed_hash=current_hash
  );
end;
$function$;

create or replace function public.jl_player_revoke_other_sessions(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  me uuid:=public.jl_player_id(p_token);
  current_hash text:=public.jl_token_hash(p_token);
  changed integer:=0;
begin
  delete from public.player_sessions
  where player_id=me
    and token_hash<>current_hash;
  get diagnostics changed=row_count;

  return jsonb_build_object('ok',true,'revoked',changed);
end;
$function$;

create or replace function public.jl_player_revoke_all_sessions(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  me uuid:=public.jl_player_id(p_token);
  changed integer:=0;
begin
  delete from public.player_sessions
  where player_id=me;
  get diagnostics changed=row_count;

  return jsonb_build_object('ok',true,'revoked',changed);
end;
$function$;

create or replace function public.jl_rotate_player_session(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  s public.player_sessions%rowtype;
  v_token text;
  v_expires_at timestamptz;
begin
  select * into s
  from public.player_sessions
  where token_hash=public.jl_token_hash(p_token)
    and expires_at>now()
  for update;

  if s.id is null then
    raise exception 'Sessão do jogador inválida ou expirada.';
  end if;

  v_token:=encode(extensions.gen_random_bytes(32),'hex');
  v_expires_at:=now()+interval '30 days';

  update public.player_sessions
  set token_hash=public.jl_token_hash(v_token),
      expires_at=v_expires_at,
      last_seen_at=now(),
      rotated_at=now()
  where id=s.id;

  return jsonb_build_object(
    'ok',true,
    'token',v_token,
    'expires_at',v_expires_at
  );
end;
$function$;

revoke all on function public.jl_player_sessions(text) from public;
revoke all on function public.jl_player_revoke_session(text,uuid) from public;
revoke all on function public.jl_player_revoke_other_sessions(text) from public;
revoke all on function public.jl_player_revoke_all_sessions(text) from public;
revoke all on function public.jl_rotate_player_session(text) from public;

grant execute on function public.jl_player_sessions(text) to anon,authenticated,service_role;
grant execute on function public.jl_player_revoke_session(text,uuid) to anon,authenticated,service_role;
grant execute on function public.jl_player_revoke_other_sessions(text) to anon,authenticated,service_role;
grant execute on function public.jl_player_revoke_all_sessions(text) to anon,authenticated,service_role;
grant execute on function public.jl_rotate_player_session(text) to anon,authenticated,service_role;

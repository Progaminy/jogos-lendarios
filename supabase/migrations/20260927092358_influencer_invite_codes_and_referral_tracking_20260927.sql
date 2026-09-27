create table if not exists public.influencers (
  id uuid primary key default extensions.gen_random_uuid(),
  name text not null,
  phone text,
  code text not null unique,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint influencers_name_len check (char_length(trim(name)) between 2 and 80),
  constraint influencers_code_format check (code ~ '^JL-[A-F0-9]{8}$')
);

create table if not exists public.influencer_referrals (
  player_id uuid primary key references public.players(id) on delete cascade,
  influencer_id uuid not null references public.influencers(id) on delete restrict,
  code_used text not null,
  created_at timestamptz not null default now()
);

create index if not exists influencer_referrals_influencer_created_idx
  on public.influencer_referrals(influencer_id, created_at desc);

alter table public.influencers enable row level security;
alter table public.influencer_referrals enable row level security;

revoke all on table public.influencers from anon, authenticated;
revoke all on table public.influencer_referrals from anon, authenticated;

create or replace function public.jl_validate_invite_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_code text := upper(trim(coalesce(p_code,'')));
  v_name text;
begin
  if v_code = '' then
    return jsonb_build_object('valid',false,'code','');
  end if;

  select i.name into v_name
  from public.influencers i
  where i.code = v_code and i.active
  limit 1;

  if v_name is null then
    return jsonb_build_object('valid',false,'code',v_code);
  end if;

  return jsonb_build_object('valid',true,'code',v_code,'influencer',v_name);
end;
$function$;

create or replace function public.jl_register_player(
  p_name text,
  p_phone text,
  p_pin text,
  p_invite_code text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_phone text := public.jl_phone(p_phone);
  v_player public.players%rowtype;
  v_token text;
  v_invite_code text := upper(trim(coalesce(p_invite_code,'')));
  v_influencer public.influencers%rowtype;
begin
  p_name := trim(coalesce(p_name,''));
  if char_length(p_name) < 2 or char_length(p_name) > 60 then
    raise exception 'Informe um nome entre 2 e 60 caracteres.';
  end if;
  if char_length(v_phone) < 8 or char_length(v_phone) > 15 then
    raise exception 'Número de telefone inválido.';
  end if;
  if coalesce(p_pin,'') !~ '^[0-9]{4,8}$' then
    raise exception 'O PIN deve ter de 4 a 8 dígitos.';
  end if;

  if v_invite_code <> '' then
    select * into v_influencer
    from public.influencers i
    where i.code = v_invite_code and i.active
    limit 1;

    if v_influencer.id is null then
      raise exception 'Código de convite inválido ou inativo.';
    end if;
  end if;

  if exists(
    select 1 from public.players
    where deleted_at is null
      and public.jl_phone(phone) = v_phone
  ) then
    raise exception 'Este número já possui uma conta. Entre nessa conta ou recupere o PIN.';
  end if;

  begin
    insert into public.players(name, phone, pin_hash)
    values (
      p_name,
      v_phone,
      extensions.crypt(p_pin, extensions.gen_salt('bf', 10))
    )
    returning * into v_player;
  exception
    when unique_violation then
      raise exception 'Este número já possui uma conta. Entre nessa conta ou recupere o PIN.';
  end;

  if v_influencer.id is not null then
    insert into public.influencer_referrals(player_id,influencer_id,code_used)
    values(v_player.id,v_influencer.id,v_invite_code);
  end if;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.player_sessions(player_id, token_hash, expires_at)
  values (
    v_player.id,
    public.jl_token_hash(v_token),
    now() + interval '30 days'
  );

  return jsonb_build_object(
    'token', v_token,
    'player', jsonb_build_object(
      'id',v_player.id,
      'name',v_player.name,
      'phone',v_player.phone,
      'balance',v_player.balance,
      'blocked',v_player.blocked
    ),
    'referral', case
      when v_influencer.id is null then null
      else jsonb_build_object(
        'influencer_id',v_influencer.id,
        'influencer',v_influencer.name,
        'code',v_invite_code
      )
    end
  );
end;
$function$;

create or replace function public.jl_register_player(
  p_name text,
  p_phone text,
  p_pin text
)
returns jsonb
language sql
security definer
set search_path to 'public','extensions'
as $function$
  select public.jl_register_player(p_name,p_phone,p_pin,null::text);
$function$;

create or replace function public.jl_admin_create_influencer(
  p_token text,
  p_name text,
  p_phone text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_name text := regexp_replace(trim(coalesce(p_name,'')),'\s+',' ','g');
  v_phone text := nullif(public.jl_phone(coalesce(p_phone,'')),'');
  v_code text;
  v_row public.influencers%rowtype;
  v_try int;
begin
  perform public.jl_require_admin(p_token);

  if char_length(v_name) < 2 or char_length(v_name) > 80 then
    raise exception 'Informe o nome do influenciador entre 2 e 80 caracteres.';
  end if;
  if v_phone is not null and (char_length(v_phone) < 8 or char_length(v_phone) > 15) then
    raise exception 'Número de telefone do influenciador inválido.';
  end if;

  for v_try in 1..12 loop
    v_code := 'JL-' || upper(encode(extensions.gen_random_bytes(4),'hex'));
    begin
      insert into public.influencers(name,phone,code)
      values(v_name,v_phone,v_code)
      returning * into v_row;
      exit;
    exception
      when unique_violation then
        v_row.id := null;
    end;
  end loop;

  if v_row.id is null then
    raise exception 'Não foi possível gerar um código único. Tente novamente.';
  end if;

  return jsonb_build_object(
    'message','Influenciador registado e código gerado.',
    'influencer',jsonb_build_object(
      'id',v_row.id,
      'name',v_row.name,
      'phone',v_row.phone,
      'code',v_row.code,
      'active',v_row.active,
      'created_at',v_row.created_at
    )
  );
end;
$function$;

create or replace function public.jl_admin_set_influencer_active(
  p_token text,
  p_influencer_id uuid,
  p_active boolean
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_name text;
begin
  perform public.jl_require_admin(p_token);

  update public.influencers
  set active = coalesce(p_active,false),
      updated_at = now()
  where id = p_influencer_id
  returning name into v_name;

  if v_name is null then
    raise exception 'Influenciador não encontrado.';
  end if;

  return jsonb_build_object(
    'message', case when p_active then 'Influenciador ativado.' else 'Influenciador desativado.' end,
    'active',p_active
  );
end;
$function$;

create or replace function public.jl_admin_influencers(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_rows jsonb;
  v_total_players bigint;
  v_referred bigint;
begin
  perform public.jl_require_admin(p_token);

  select count(*) into v_total_players
  from public.players p
  where p.deleted_at is null;

  select count(*) into v_referred
  from public.influencer_referrals r
  join public.players p on p.id=r.player_id
  where p.deleted_at is null;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb)
    into v_rows
  from (
    select
      i.id,
      i.name,
      i.phone,
      i.code,
      i.active,
      i.created_at,
      i.updated_at,
      (
        select count(*)
        from public.influencer_referrals r
        join public.players p on p.id=r.player_id
        where r.influencer_id=i.id
          and p.deleted_at is null
      ) as referral_count,
      (
        select coalesce(jsonb_agg(jsonb_build_object(
          'player_id',p.id,
          'name',p.name,
          'phone',p.phone,
          'player_created_at',p.created_at,
          'referred_at',r.created_at,
          'code_used',r.code_used
        ) order by r.created_at desc),'[]'::jsonb)
        from public.influencer_referrals r
        join public.players p on p.id=r.player_id
        where r.influencer_id=i.id
          and p.deleted_at is null
      ) as registrations
    from public.influencers i
  ) x;

  return jsonb_build_object(
    'influencers',v_rows,
    'influencer_count',(select count(*) from public.influencers),
    'active_influencer_count',(select count(*) from public.influencers where active),
    'referred_players',v_referred,
    'without_invite_code',greatest(v_total_players-v_referred,0),
    'total_players',v_total_players
  );
end;
$function$;

revoke execute on function public.jl_validate_invite_code(text) from public;
grant execute on function public.jl_validate_invite_code(text) to anon, authenticated;

revoke execute on function public.jl_register_player(text,text,text,text) from public;
grant execute on function public.jl_register_player(text,text,text,text) to anon, authenticated;

revoke execute on function public.jl_register_player(text,text,text) from public;
grant execute on function public.jl_register_player(text,text,text) to anon, authenticated;

revoke execute on function public.jl_admin_create_influencer(text,text,text) from public;
grant execute on function public.jl_admin_create_influencer(text,text,text) to anon, authenticated;

revoke execute on function public.jl_admin_set_influencer_active(text,uuid,boolean) from public;
grant execute on function public.jl_admin_set_influencer_active(text,uuid,boolean) to anon, authenticated;

revoke execute on function public.jl_admin_influencers(text) from public;
grant execute on function public.jl_admin_influencers(text) to anon, authenticated;

notify pgrst, 'reload schema';

create or replace function public.jl_phone(p_phone text)
returns text
language sql
immutable
set search_path=public
as $$
  with d as (
    select regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g') as digits
  )
  select case
    when digits ~ '^00258[0-9]{9}$' then substr(digits, 6)
    when digits ~ '^258[0-9]{9}$' then substr(digits, 4)
    else digits
  end
  from d;
$$;

update public.players
set phone = public.jl_phone(phone),
    updated_at = now()
where deleted_at is null
  and phone <> public.jl_phone(phone);

create unique index if not exists players_active_phone_canonical_key
on public.players (public.jl_phone(phone))
where deleted_at is null;

create or replace function public.jl_register_player(
  p_name text,
  p_phone text,
  p_pin text
)
returns jsonb
language plpgsql
security definer
set search_path='public','extensions'
as $$
declare
  v_phone text := public.jl_phone(p_phone);
  v_player public.players%rowtype;
  v_token text;
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

  if exists(
    select 1
    from public.players
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
    )
  );
end;
$$;

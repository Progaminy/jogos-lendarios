-- Ponto 18 — recuperação de PIN.
-- Limite: no máximo 3 novos pedidos por telefone em 24 horas.
-- Código: válido por 24 horas a partir da emissão.
-- Mantém resposta pública neutra, e-mail opcional, hash bcrypt/crypt e limite de 5 tentativas.

create index if not exists pin_recovery_phone_requested_idx
  on public.pin_recovery_requests(phone, requested_at desc);

create or replace function public.jl_request_pin_recovery(
  p_phone text,
  p_email text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_phone text:=public.jl_phone(p_phone);
  v_email text:=nullif(lower(trim(coalesce(p_email,''))),'');
  v_player public.players%rowtype;
  v_message text:='Pedido enviado ao administrador para confirmação.';
  v_requests_24h integer:=0;
begin
  if char_length(v_phone)<8 or char_length(v_phone)>15 then
    return jsonb_build_object('ok',false,'message','Informe um telefone válido.');
  end if;

  if v_email is not null
     and v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
    return jsonb_build_object('ok',false,'message','Informe um e-mail válido ou deixe o campo vazio.');
  end if;

  -- Resposta neutra: o limite não revela se a conta existe.
  select count(*)::integer
  into v_requests_24h
  from public.pin_recovery_requests
  where phone=v_phone
    and requested_at>=now()-interval '24 hours';

  if v_requests_24h>=3 then
    return jsonb_build_object('ok',true,'message',v_message);
  end if;

  select * into v_player
  from public.players
  where public.jl_phone(phone)=v_phone
    and deleted_at is null
  limit 1;

  if v_player.id is not null then
    if exists(
      select 1 from public.pin_recovery_requests
      where player_id=v_player.id
        and status in ('pending_admin','sending','code_sent')
    ) then
      return jsonb_build_object('ok',true,'message',v_message);
    end if;

    begin
      insert into public.pin_recovery_requests(player_id,phone,recovery_email,status)
      values(v_player.id,v_phone,v_email,'pending_admin');
    exception when unique_violation then
      null;
    end;
  else
    if exists(
      select 1 from public.pin_recovery_requests
      where player_id is null
        and phone=v_phone
        and status in ('pending_admin','sending','code_sent')
    ) then
      return jsonb_build_object('ok',true,'message',v_message);
    end if;

    begin
      insert into public.pin_recovery_requests(player_id,phone,recovery_email,status)
      values(null,v_phone,v_email,'pending_admin');
    exception when unique_violation then
      null;
    end;
  end if;

  return jsonb_build_object('ok',true,'message',v_message);
end;
$function$;

create or replace function public.jl_admin_issue_recovery_code(
  p_token text,
  p_request_id uuid,
  p_code text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  r public.pin_recovery_requests%rowtype;
  pname text;
  v_expires_at timestamptz;
begin
  perform public.jl_require_admin(p_token);

  if coalesce(p_code,'') !~ '^[0-9]{6}$' then
    raise exception 'Código de recuperação inválido.';
  end if;

  select * into r
  from public.pin_recovery_requests
  where id=p_request_id
  for update;

  if r.id is null then raise exception 'Pedido não encontrado.'; end if;
  if r.status not in ('pending_admin','code_sent','expired') then
    raise exception 'Este pedido não pode receber um novo código neste estado.';
  end if;

  select name into pname
  from public.players
  where id=r.player_id
    and deleted_at is null;

  if pname is null then raise exception 'Conta indisponível.'; end if;

  v_expires_at:=now()+interval '24 hours';

  update public.pin_recovery_requests
  set status='code_sent',
      otp_hash=extensions.crypt(p_code,extensions.gen_salt('bf',10)),
      otp_expires_at=v_expires_at,
      otp_attempts=0,
      approved_at=coalesce(approved_at,now()),
      sent_at=now(),
      updated_at=now()
  where id=r.id;

  insert into public.audit_log(action,details)
  values(
    'admin_issue_pin_recovery_code',
    jsonb_build_object(
      'request_id',r.id,
      'player_id',r.player_id,
      'expires_at',v_expires_at
    )
  );

  return jsonb_build_object(
    'ok',true,
    'request_id',r.id,
    'name',pname,
    'phone',r.phone,
    'expires_at',v_expires_at,
    'message','Código criado. Envie-o ao jogador por um canal confirmado.'
  );
end;
$function$;

create or replace function public.jl_admin_prepare_recovery_send(
  p_token text,
  p_request_id uuid,
  p_code text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  r public.pin_recovery_requests%rowtype;
  pname text;
  v_expires_at timestamptz;
begin
  perform public.jl_require_admin(p_token);

  if coalesce(p_code,'') !~ '^[0-9]{6}$' then
    raise exception 'Código de recuperação inválido.';
  end if;

  select * into r
  from public.pin_recovery_requests
  where id=p_request_id
  for update;

  if r.id is null then raise exception 'Pedido não encontrado.'; end if;
  if r.status<>'pending_admin' then
    raise exception 'Este pedido já foi processado.';
  end if;

  select name into pname
  from public.players
  where id=r.player_id
    and deleted_at is null;

  if pname is null then raise exception 'Conta indisponível.'; end if;
  if r.recovery_email is null then
    raise exception 'Este pedido não possui e-mail de recuperação.';
  end if;

  v_expires_at:=now()+interval '24 hours';

  update public.pin_recovery_requests
  set status='sending',
      otp_hash=extensions.crypt(p_code,extensions.gen_salt('bf',10)),
      otp_expires_at=v_expires_at,
      otp_attempts=0,
      approved_at=now(),
      updated_at=now()
  where id=r.id;

  return jsonb_build_object(
    'ok',true,
    'request_id',r.id,
    'email',r.recovery_email,
    'phone',r.phone,
    'name',pname,
    'expires_at',v_expires_at
  );
end;
$function$;

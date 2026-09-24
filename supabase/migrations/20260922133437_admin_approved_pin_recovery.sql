create table if not exists public.pin_recovery_requests (
  id uuid primary key default extensions.gen_random_uuid(),
  player_id uuid not null references public.players(id) on delete cascade,
  phone text not null,
  recovery_email text not null,
  status text not null default 'pending_admin'
    check (status in ('pending_admin','sending','code_sent','rejected','completed','expired','cancelled')),
  otp_hash text,
  otp_expires_at timestamptz,
  otp_attempts integer not null default 0,
  requested_at timestamptz not null default now(),
  approved_at timestamptz,
  sent_at timestamptz,
  completed_at timestamptz,
  rejected_at timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.pin_recovery_requests enable row level security;

create index if not exists pin_recovery_requests_player_idx
  on public.pin_recovery_requests(player_id, requested_at desc);
create index if not exists pin_recovery_requests_status_idx
  on public.pin_recovery_requests(status, requested_at desc);

create or replace function public.jl_request_pin_recovery(p_phone text, p_email text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_phone text:=public.jl_phone(p_phone);
  v_email text:=lower(trim(coalesce(p_email,'')));
  v_player public.players%rowtype;
begin
  if char_length(v_phone)<8 or char_length(v_phone)>15
     or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'Informe um telefone e um e-mail válidos.';
  end if;

  select * into v_player from public.players where phone=v_phone limit 1;

  -- resposta genérica para não revelar se a conta existe.
  if v_player.id is null then
    return jsonb_build_object(
      'ok',true,
      'message','Se a conta existir, o pedido será enviado ao administrador para confirmação.'
    );
  end if;

  update public.pin_recovery_requests
  set status='cancelled',updated_at=now()
  where player_id=v_player.id
    and status in ('pending_admin','sending','code_sent');

  insert into public.pin_recovery_requests(player_id,phone,recovery_email,status)
  values(v_player.id,v_phone,v_email,'pending_admin');

  return jsonb_build_object(
    'ok',true,
    'message','Pedido recebido. O administrador vai confirmar a identidade antes do envio do código.'
  );
end;
$$;

create or replace function public.jl_admin_recovery_requests(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare rows jsonb;
begin
  perform public.jl_require_admin(p_token);

  update public.pin_recovery_requests
  set status='expired',updated_at=now()
  where status='code_sent'
    and otp_expires_at is not null
    and otp_expires_at<=now();

  select coalesce(jsonb_agg(x order by x.requested_at desc),'[]'::jsonb)
  into rows
  from (
    select
      r.id,r.status,r.phone,r.recovery_email,r.requested_at,
      r.approved_at,r.sent_at,r.otp_expires_at,r.completed_at,r.rejected_at,
      p.name,p.id as player_id
    from public.pin_recovery_requests r
    join public.players p on p.id=r.player_id
    where r.status in ('pending_admin','sending','code_sent')
       or r.requested_at>=now()-interval '2 days'
    order by r.requested_at desc
    limit 150
  ) x;

  return rows;
end;
$$;

create or replace function public.jl_admin_prepare_recovery_send(
  p_token text,
  p_request_id uuid,
  p_code text
)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare r public.pin_recovery_requests%rowtype; pname text;
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
  if r.status<>'pending_admin' then raise exception 'Este pedido já foi processado.'; end if;

  select name into pname from public.players where id=r.player_id;

  update public.pin_recovery_requests
  set status='sending',
      otp_hash=extensions.crypt(p_code,extensions.gen_salt('bf',10)),
      otp_expires_at=now()+interval '10 minutes',
      otp_attempts=0,
      approved_at=now(),
      updated_at=now()
  where id=r.id;

  return jsonb_build_object(
    'ok',true,
    'request_id',r.id,
    'email',r.recovery_email,
    'phone',r.phone,
    'name',pname
  );
end;
$$;

create or replace function public.jl_admin_mark_recovery_sent(
  p_token text,
  p_request_id uuid
)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
begin
  perform public.jl_require_admin(p_token);
  update public.pin_recovery_requests
  set status='code_sent',sent_at=now(),updated_at=now()
  where id=p_request_id and status='sending';
  if not found then raise exception 'Pedido não está pronto para envio.'; end if;
  return true;
end;
$$;

create or replace function public.jl_admin_recovery_send_failed(
  p_token text,
  p_request_id uuid
)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
begin
  perform public.jl_require_admin(p_token);
  update public.pin_recovery_requests
  set status='pending_admin',
      otp_hash=null,otp_expires_at=null,otp_attempts=0,
      approved_at=null,updated_at=now()
  where id=p_request_id and status='sending';
  return true;
end;
$$;

create or replace function public.jl_admin_reject_recovery(
  p_token text,
  p_request_id uuid
)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
begin
  perform public.jl_require_admin(p_token);
  update public.pin_recovery_requests
  set status='rejected',rejected_at=now(),updated_at=now(),
      otp_hash=null,otp_expires_at=null
  where id=p_request_id and status in ('pending_admin','sending');
  if not found then raise exception 'Pedido não pode ser rejeitado neste estado.'; end if;
  return true;
end;
$$;

create or replace function public.jl_confirm_pin_recovery(
  p_phone text,
  p_email text,
  p_code text,
  p_new_pin text
)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  v_phone text:=public.jl_phone(p_phone);
  v_email text:=lower(trim(coalesce(p_email,'')));
  r public.pin_recovery_requests%rowtype;
begin
  if coalesce(p_code,'') !~ '^[0-9]{6}$'
     or coalesce(p_new_pin,'') !~ '^[0-9]{4,8}$' then
    raise exception 'Código ou novo PIN inválido.';
  end if;

  select pr.* into r
  from public.pin_recovery_requests pr
  where pr.phone=v_phone
    and pr.recovery_email=v_email
    and pr.status='code_sent'
  order by pr.sent_at desc
  limit 1
  for update;

  if r.id is null or r.otp_expires_at<=now() then
    raise exception 'Código inválido ou expirado.';
  end if;

  if r.otp_attempts>=5 then
    raise exception 'Código bloqueado. Faça um novo pedido de recuperação.';
  end if;

  if extensions.crypt(p_code,r.otp_hash)<>r.otp_hash then
    update public.pin_recovery_requests
    set otp_attempts=otp_attempts+1,updated_at=now()
    where id=r.id;
    raise exception 'Código inválido ou expirado.';
  end if;

  update public.players
  set pin_hash=extensions.crypt(p_new_pin,extensions.gen_salt('bf',10)),
      updated_at=now()
  where id=r.player_id;

  delete from public.player_sessions where player_id=r.player_id;

  update public.pin_recovery_requests
  set status='completed',completed_at=now(),updated_at=now(),
      otp_hash=null,otp_expires_at=null
  where id=r.id;

  return jsonb_build_object(
    'ok',true,
    'message','PIN alterado com sucesso. Entre novamente com o novo PIN.'
  );
end;
$$;

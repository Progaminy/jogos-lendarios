alter table public.pin_recovery_requests
  alter column recovery_email drop not null;

create or replace function public.jl_request_pin_recovery(p_phone text, p_email text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_phone text:=public.jl_phone(p_phone);
  v_email text:=nullif(lower(trim(coalesce(p_email,''))),'');
  v_player public.players%rowtype;
  v_message text:='Se a conta existir, o pedido será enviado ao administrador para confirmação.';
begin
  if char_length(v_phone)<8 or char_length(v_phone)>15 then
    return jsonb_build_object('ok',false,'message','Informe um telefone válido.');
  end if;

  if v_email is not null
     and v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    return jsonb_build_object('ok',false,'message','Informe um e-mail válido ou deixe o campo vazio.');
  end if;

  select * into v_player
  from public.players
  where phone=v_phone and deleted_at is null
  limit 1;

  if v_player.id is null then
    return jsonb_build_object('ok',true,'message',v_message);
  end if;

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

  return jsonb_build_object('ok',true,'message',v_message);
end;
$function$;

create or replace function public.jl_confirm_pin_recovery(
  p_phone text,
  p_email text,
  p_code text,
  p_new_pin text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_phone text:=public.jl_phone(p_phone);
  r public.pin_recovery_requests%rowtype;
  v_attempts integer;
begin
  if coalesce(p_code,'') !~ '^[0-9]{6}$'
     or coalesce(p_new_pin,'') !~ '^[0-9]{4,8}$' then
    return jsonb_build_object('ok',false,'error','Código inválido ou expirado.');
  end if;

  select pr.* into r
  from public.pin_recovery_requests pr
  join public.players p on p.id=pr.player_id and p.deleted_at is null
  where pr.phone=v_phone
    and pr.status='code_sent'
  order by pr.sent_at desc nulls last, pr.requested_at desc
  limit 1
  for update of pr;

  if r.id is null then
    return jsonb_build_object('ok',false,'error','Código inválido ou expirado.');
  end if;

  if r.otp_expires_at is null or r.otp_expires_at<=now() then
    update public.pin_recovery_requests
    set status='expired',otp_hash=null,otp_expires_at=null,updated_at=now()
    where id=r.id;
    return jsonb_build_object('ok',false,'error','Código inválido ou expirado.');
  end if;

  if r.otp_attempts>=5 then
    update public.pin_recovery_requests
    set status='expired',otp_hash=null,otp_expires_at=null,updated_at=now()
    where id=r.id;
    return jsonb_build_object('ok',false,'error','Código bloqueado. Faça um novo pedido de recuperação.');
  end if;

  if r.otp_hash is null or extensions.crypt(p_code,r.otp_hash)<>r.otp_hash then
    v_attempts:=r.otp_attempts+1;
    update public.pin_recovery_requests
    set otp_attempts=v_attempts,
        status=case when v_attempts>=5 then 'expired' else status end,
        otp_hash=case when v_attempts>=5 then null else otp_hash end,
        otp_expires_at=case when v_attempts>=5 then null else otp_expires_at end,
        updated_at=now()
    where id=r.id;

    return jsonb_build_object(
      'ok',false,
      'error',case when v_attempts>=5
        then 'Código bloqueado. Faça um novo pedido de recuperação.'
        else 'Código inválido ou expirado.'
      end,
      'attempts_remaining',greatest(0,5-v_attempts)
    );
  end if;

  update public.players
  set pin_hash=extensions.crypt(p_new_pin,extensions.gen_salt('bf',10)),
      updated_at=now()
  where id=r.player_id and deleted_at is null;

  if not found then
    update public.pin_recovery_requests
    set status='cancelled',otp_hash=null,otp_expires_at=null,updated_at=now()
    where id=r.id;
    return jsonb_build_object('ok',false,'error','Conta indisponível.');
  end if;

  delete from public.player_sessions where player_id=r.player_id;

  update public.pin_recovery_requests
  set status='completed',
      completed_at=now(),
      updated_at=now(),
      otp_hash=null,
      otp_expires_at=null
  where id=r.id;

  return jsonb_build_object(
    'ok',true,
    'message','PIN alterado com sucesso. Entre novamente com o novo PIN.'
  );
end;
$function$;

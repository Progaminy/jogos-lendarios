alter table public.pin_recovery_requests
  alter column player_id drop not null;

create unique index if not exists pin_recovery_one_active_unmatched_phone_idx
on public.pin_recovery_requests(phone)
where player_id is null
  and status in ('pending_admin','sending','code_sent');

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
  v_message text:='Pedido enviado ao administrador para confirmação.';
begin
  if char_length(v_phone)<8 or char_length(v_phone)>15 then
    return jsonb_build_object('ok',false,'message','Informe um telefone válido.');
  end if;
  if v_email is not null
     and v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
    return jsonb_build_object('ok',false,'message','Informe um e-mail válido ou deixe o campo vazio.');
  end if;

  select * into v_player
  from public.players
  where public.jl_phone(phone)=v_phone and deleted_at is null
  limit 1;

  if v_player.id is not null then
    if exists(select 1 from public.pin_recovery_requests where player_id=v_player.id and status in ('pending_admin','sending','code_sent')) then
      return jsonb_build_object('ok',true,'message',v_message);
    end if;
    begin
      insert into public.pin_recovery_requests(player_id,phone,recovery_email,status)
      values(v_player.id,v_phone,v_email,'pending_admin');
    exception when unique_violation then null;
    end;
  else
    if exists(select 1 from public.pin_recovery_requests where player_id is null and phone=v_phone and status in ('pending_admin','sending','code_sent')) then
      return jsonb_build_object('ok',true,'message',v_message);
    end if;
    begin
      insert into public.pin_recovery_requests(player_id,phone,recovery_email,status)
      values(null,v_phone,v_email,'pending_admin');
    exception when unique_violation then null;
    end;
  end if;
  return jsonb_build_object('ok',true,'message',v_message);
end;
$function$;

create or replace function public.jl_admin_recovery_requests(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare rows jsonb;
begin
  perform public.jl_require_admin(p_token);
  update public.pin_recovery_requests
  set status='expired',updated_at=now()
  where status='code_sent' and otp_expires_at is not null and otp_expires_at<=now();

  select coalesce(jsonb_agg(x order by x.requested_at desc),'[]'::jsonb)
  into rows
  from (
    select r.id,r.status,r.phone,r.recovery_email,r.requested_at,
           r.approved_at,r.sent_at,r.otp_expires_at,r.completed_at,r.rejected_at,
           coalesce(p.name,'Conta não localizada') as name,
           p.id as player_id,
           (p.id is not null) as account_found
    from public.pin_recovery_requests r
    left join public.players p on p.id=r.player_id and p.deleted_at is null
    where r.status in ('pending_admin','sending','code_sent')
       or r.requested_at>=now()-interval '2 days'
    order by r.requested_at desc
    limit 150
  ) x;

  return rows;
end;
$function$;

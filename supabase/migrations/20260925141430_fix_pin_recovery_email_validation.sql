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
     and v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
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

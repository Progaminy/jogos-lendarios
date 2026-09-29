begin;

update public.jl_aviator_rounds
   set status='CANCELLED',
       settled_at=coalesce(settled_at,clock_timestamp())
 where status in ('OPEN','LOCKED','FLYING','CRASHED');

update public.jl_aviator_settings
   set enabled=false,
       one_round_test=false,
       maintenance_message='Aviator brevemente.',
       updated_at=clock_timestamp()
 where id=true;

do $reopen$
declare
  v_admin uuid;
  v_token text:='admin-reopen-'||gen_random_uuid()::text;
  v_round bigint;
  v_result jsonb;
  v_unauthorized boolean:=false;
  v_blocked boolean:=false;
  v_enabled boolean;
begin
  insert into public.admin_accounts(
    display_name,role,code_hash,code_scheme,active
  )
  values(
    'AVIATOR REOPEN TEST','admin','test-hash','bcrypt',true
  )
  returning id into v_admin;

  insert into public.admin_sessions(admin_id,token_hash,expires_at)
  values(
    v_admin,
    public.jl_token_hash(v_token),
    clock_timestamp()+interval '1 hour'
  );

  begin
    perform public.jl_aviator_admin_reopen('invalid-admin-token');
  exception
    when others then
      v_unauthorized:=true;
  end;

  if not v_unauthorized then
    raise exception 'token administrativo inválido conseguiu reabrir Aviator';
  end if;

  insert into public.jl_aviator_rounds(
    status,betting_closes_at,takeoff_at
  )
  values(
    'OPEN',
    clock_timestamp()+interval '30 seconds',
    clock_timestamp()+interval '33 seconds'
  )
  returning id into v_round;

  begin
    perform public.jl_aviator_admin_reopen(v_token);
  exception
    when others then
      if position('Aguarde a rodada atual terminar' in sqlerrm)>0 then
        v_blocked:=true;
      else
        raise;
      end if;
  end;

  if not v_blocked then
    raise exception 'reabertura ocorreu com rodada transitória ainda viva';
  end if;

  select enabled into v_enabled
  from public.jl_aviator_settings
  where id=true;

  if v_enabled is distinct from false then
    raise exception 'reabertura bloqueada não pode alterar enabled';
  end if;

  update public.jl_aviator_rounds
     set status='CANCELLED',
         settled_at=clock_timestamp()
   where id=v_round;

  v_result:=public.jl_aviator_admin_reopen(v_token);

  if coalesce((v_result->>'enabled')::boolean,false) is distinct from true
     or coalesce((v_result->>'already_open')::boolean,true) then
    raise exception 'reabertura válida falhou: %',v_result;
  end if;

  select enabled into v_enabled
  from public.jl_aviator_settings
  where id=true;

  if v_enabled is distinct from true then
    raise exception 'settings.enabled deveria estar true após reabrir';
  end if;

  v_result:=public.jl_aviator_admin_reopen(v_token);

  if coalesce((v_result->>'already_open')::boolean,false) is distinct from true then
    raise exception 'segunda reabertura deveria ser idempotente: %',v_result;
  end if;
end
$reopen$;

rollback;

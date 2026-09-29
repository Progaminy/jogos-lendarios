begin;

update public.jl_aviator_rounds
   set status='CANCELLED',
       settled_at=coalesce(settled_at,clock_timestamp())
 where status in ('OPEN','LOCKED','FLYING','CRASHED');

update public.jl_aviator_settings
   set enabled=true,
       one_round_test=false,
       maintenance_message='Aviator brevemente.',
       updated_at=clock_timestamp()
 where id=true;

do $close$
declare
  v_admin uuid;
  v_admin_token text:='admin-close-'||gen_random_uuid()::text;
  v_p1 uuid;
  v_p2 uuid;
  v_phone1 text:='close-p1-'||gen_random_uuid()::text;
  v_phone2 text:='close-p2-'||gen_random_uuid()::text;
  v_t1 text:='player-close-1-'||gen_random_uuid()::text;
  v_t2 text:='player-close-2-'||gen_random_uuid()::text;
  v_round bigint;
  v_bet jsonb;
  v_close jsonb;
  v_open jsonb;
  v_before bigint;
  v_after bigint;
  v_status text;
  v_enabled boolean;
  v_rejected boolean:=false;
  v_unauthorized boolean:=false;
begin
  insert into public.admin_accounts(
    display_name,role,code_hash,code_scheme,active
  )
  values(
    'AVIATOR CLOSE TEST','admin','test-hash','bcrypt',true
  )
  returning id into v_admin;

  insert into public.admin_sessions(admin_id,token_hash,expires_at)
  values(
    v_admin,
    public.jl_token_hash(v_admin_token),
    clock_timestamp()+interval '1 hour'
  );

  insert into public.players(name,phone,pin_hash,balance)
  values('AVIATOR CLOSE P1',v_phone1,'x',100)
  returning id into v_p1;

  insert into public.players(name,phone,pin_hash,balance)
  values('AVIATOR CLOSE P2',v_phone2,'x',100)
  returning id into v_p2;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values
    (v_p1,public.jl_token_hash(v_t1),clock_timestamp()+interval '1 hour'),
    (v_p2,public.jl_token_hash(v_t2),clock_timestamp()+interval '1 hour');

  insert into public.jl_aviator_rounds(
    status,betting_closes_at,takeoff_at
  )
  values(
    'OPEN',
    clock_timestamp()+interval '30 seconds',
    clock_timestamp()+interval '33 seconds'
  )
  returning id into v_round;

  v_bet:=public.jl_aviator_place_bet(
    v_t1,10,'admin-close-bet-'||v_round::text,null
  );

  if (v_bet->>'bet_id')::bigint is null then
    raise exception 'aposta inicial não foi confirmada';
  end if;

  begin
    perform public.jl_aviator_admin_close('invalid-admin-token');
  exception
    when others then
      v_unauthorized:=true;
  end;

  if not v_unauthorized then
    raise exception 'token administrativo inválido conseguiu fechar Aviator';
  end if;

  v_close:=public.jl_aviator_admin_close(v_admin_token);

  if coalesce((v_close->>'enabled')::boolean,true) then
    raise exception 'fecho administrativo não desativou Aviator: %',v_close;
  end if;

  if v_close->>'maintenance_message'<>'Aviator brevemente.' then
    raise exception 'mensagem de manutenção incorreta: %',v_close;
  end if;

  if coalesce((v_close->>'draining')::boolean,false) is distinct from true then
    raise exception 'rodada com aposta ativa deve ficar em drenagem segura: %',v_close;
  end if;

  select enabled into v_enabled
  from public.jl_aviator_settings
  where id=true;

  if v_enabled is distinct from false then
    raise exception 'settings.enabled deveria estar false';
  end if;

  select status into v_status
  from public.jl_aviator_rounds
  where id=v_round;

  if v_status<>'OPEN' then
    raise exception 'rodada financiada não deve ser abortada no fecho; status=%',v_status;
  end if;

  begin
    perform public.jl_aviator_place_bet(
      v_t2,10,'admin-close-late-'||v_round::text,null
    );
  exception
    when others then
      if position('manutencao' in lower(sqlerrm))>0 then
        v_rejected:=true;
      else
        raise;
      end if;
  end;

  if not v_rejected then
    raise exception 'nova aposta entrou depois do fecho administrativo';
  end if;

  select count(*) into v_before
  from public.jl_aviator_rounds;

  v_open:=public.jl_aviator_open_next_if_due();

  select count(*) into v_after
  from public.jl_aviator_rounds;

  if v_after<>v_before then
    raise exception 'nova rodada abriu depois do fecho administrativo';
  end if;

  if coalesce((v_open->>'maintenance')::boolean,false) is distinct from true then
    raise exception 'open_next_if_due deveria indicar manutenção: %',v_open;
  end if;

  if not exists(
    select 1
    from public.jl_aviator_bets
    where id=(v_bet->>'bet_id')::bigint
      and status='ACTIVE'
      and stake=10
  ) then
    raise exception 'aposta anterior ao fecho deixou de estar protegida';
  end if;
end
$close$;

rollback;

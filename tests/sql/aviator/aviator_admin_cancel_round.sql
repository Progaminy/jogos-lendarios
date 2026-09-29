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

do $setup$
declare
  v_admin uuid;
  v_token text:='cancel-admin-'||gen_random_uuid()::text;
  v_p1 uuid;
  v_p2 uuid;
  v_t1 text:='cancel-p1-'||gen_random_uuid()::text;
  v_t2 text:='cancel-p2-'||gen_random_uuid()::text;
  v_round bigint;
  v_b1 jsonb;
  v_b2 jsonb;
  v_rejected boolean:=false;
begin
  insert into public.admin_accounts(
    display_name,role,code_hash,code_scheme,active
  )
  values('AVIATOR CANCEL TEST','admin','test-hash','bcrypt',true)
  returning id into v_admin;

  insert into public.admin_sessions(admin_id,token_hash,expires_at)
  values(
    v_admin,
    public.jl_token_hash(v_token),
    clock_timestamp()+interval '1 hour'
  );

  insert into public.players(name,phone,pin_hash,balance)
  values('CANCEL P1','cancel-p1-'||gen_random_uuid()::text,'x',100)
  returning id into v_p1;

  insert into public.players(name,phone,pin_hash,balance)
  values('CANCEL P2','cancel-p2-'||gen_random_uuid()::text,'x',100)
  returning id into v_p2;

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values
    (v_p1,public.jl_token_hash(v_t1),clock_timestamp()+interval '1 hour'),
    (v_p2,public.jl_token_hash(v_t2),clock_timestamp()+interval '1 hour');

  update public.jl_aviator_settings
     set enabled=true,updated_at=clock_timestamp()
   where id=true;

  insert into public.jl_aviator_rounds(
    status,betting_closes_at,takeoff_at
  )
  values(
    'OPEN',
    clock_timestamp()+interval '30 seconds',
    clock_timestamp()+interval '33 seconds'
  )
  returning id into v_round;

  v_b1:=public.jl_aviator_place_bet(
    v_t1,10,'cancel-b1-'||v_round::text,null
  );
  v_b2:=public.jl_aviator_place_bet(
    v_t2,15,'cancel-b2-'||v_round::text,null
  );

  begin
    perform public.jl_aviator_admin_cancel_round(
      v_token,v_round,'não'
    );
  exception
    when others then
      if position('pelo menos 5 caracteres' in sqlerrm)>0 then
        v_rejected:=true;
      else
        raise;
      end if;
  end;

  if not v_rejected then
    raise exception 'motivo curto deveria ser rejeitado';
  end if;

  if exists(
    select 1
    from public.jl_aviator_bets
    where round_id=v_round and status<>'ACTIVE'
  ) then
    raise exception 'motivo inválido alterou apostas';
  end if;

  perform set_config('jl.cancel_token',v_token,true);
  perform set_config('jl.cancel_round',v_round::text,true);
  perform set_config('jl.cancel_b1',(v_b1->>'bet_id'),true);
  perform set_config('jl.cancel_b2',(v_b2->>'bet_id'),true);
  perform set_config('jl.cancel_p1',v_p1::text,true);
  perform set_config('jl.cancel_p2',v_p2::text,true);
end
$setup$;

set local role anon;

select public.jl_aviator_admin_cancel_round(
  current_setting('jl.cancel_token',true),
  current_setting('jl.cancel_round',true)::bigint,
  'Falha técnica identificada pelo administrador'
);

reset role;

do $verify$
declare
  v_round bigint:=current_setting('jl.cancel_round',true)::bigint;
  v_p1 uuid:=current_setting('jl.cancel_p1',true)::uuid;
  v_p2 uuid:=current_setting('jl.cancel_p2',true)::uuid;
  v_token text:=current_setting('jl.cancel_token',true);
  v_balance1 numeric;
  v_balance2 numeric;
  v_refunds bigint;
  v_audit bigint;
begin
  if not exists(
    select 1
    from public.jl_aviator_rounds
    where id=v_round
      and status='CANCELLED'
      and admin_cancelled_at is not null
      and admin_cancel_reason='Falha técnica identificada pelo administrador'
      and admin_cancelled_by is not null
      and admin_cancel_refunded_bets=2
      and admin_cancel_refunded_total=25
  ) then
    raise exception 'metadados do cancelamento administrativo incorretos';
  end if;

  if (
    select count(*)
    from public.jl_aviator_bets
    where round_id=v_round
      and status='REFUNDED'
      and payout=stake
      and refunded_at is not null
      and refund_transaction_id is not null
  )<>2 then
    raise exception 'duas apostas deveriam estar REFUNDED';
  end if;

  select balance into v_balance1 from public.players where id=v_p1;
  select balance into v_balance2 from public.players where id=v_p2;

  if v_balance1<>100 or v_balance2<>100 then
    raise exception 'saldos não foram restaurados: %, %',v_balance1,v_balance2;
  end if;

  select count(*) into v_refunds
  from public.transactions
  where player_id in (v_p1,v_p2)
    and kind='aviator_refund'
    and status='completed';

  if v_refunds<>2 then
    raise exception 'esperava 2 transações de reembolso, obteve %',v_refunds;
  end if;

  select count(*) into v_audit
  from public.audit_log
  where action='aviator.round_admin_cancelled'
    and target_type='aviator_round'
    and target_id=v_round::text
    and details->>'reason'='Falha técnica identificada pelo administrador';

  if v_audit<>1 then
    raise exception 'cancelamento não foi auditado corretamente';
  end if;

  -- Repetição é idempotente: não cria novo reembolso.
  perform public.jl_aviator_admin_cancel_round(
    v_token,v_round,'Motivo diferente não deve substituir o original'
  );

  select count(*) into v_refunds
  from public.transactions
  where player_id in (v_p1,v_p2)
    and kind='aviator_refund'
    and status='completed';

  if v_refunds<>2 then
    raise exception 'cancelamento repetido duplicou reembolso: %',v_refunds;
  end if;
end
$verify$;

rollback;

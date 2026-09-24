-- Jogos Lendários — consolidação de segurança, recuperação, invariantes financeiros e poderes do admin.
-- 2026-09-24. Esta migration é deliberadamente posterior às migrations legadas de 8 dígitos.

alter table public.players
  add column if not exists deleted_at timestamptz,
  add column if not exists deleted_by_admin boolean not null default false;

-- RECUPERAÇÃO: manter apenas o pedido ativo mais recente antes de impor unicidade.
with ranked as (
  select id,
         row_number() over (
           partition by player_id
           order by requested_at desc, id desc
         ) as rn
  from public.pin_recovery_requests
  where status in ('pending_admin','sending','code_sent')
)
update public.pin_recovery_requests r
set status='cancelled',
    otp_hash=null,
    otp_expires_at=null,
    updated_at=now()
from ranked x
where r.id=x.id and x.rn>1;

create unique index if not exists pin_recovery_one_active_per_player_idx
on public.pin_recovery_requests(player_id)
where status in ('pending_admin','sending','code_sent');

create or replace function public.jl_request_pin_recovery(p_phone text,p_email text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare
  v_phone text:=public.jl_phone(p_phone);
  v_email text:=lower(trim(coalesce(p_email,'')));
  v_player public.players%rowtype;
  v_message text:='Se a conta existir, o pedido será enviado ao administrador para confirmação.';
begin
  if char_length(v_phone)<8 or char_length(v_phone)>15
     or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    return jsonb_build_object('ok',false,'message','Informe um telefone e um e-mail válidos.');
  end if;

  select * into v_player
  from public.players
  where phone=v_phone and deleted_at is null
  limit 1;

  -- A resposta é deliberadamente igual para conta existente ou inexistente.
  if v_player.id is null then
    return jsonb_build_object('ok',true,'message',v_message);
  end if;

  -- Um terceiro não pode cancelar/substituir um pedido ativo nem trocar o e-mail.
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
$$;

create or replace function public.jl_admin_issue_recovery_code(
  p_token text,
  p_request_id uuid,
  p_code text
)
returns jsonb language plpgsql security definer set search_path=public,extensions
as $$
declare
  r public.pin_recovery_requests%rowtype;
  pname text;
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

  select name into pname from public.players where id=r.player_id and deleted_at is null;
  if pname is null then raise exception 'Conta indisponível.'; end if;

  update public.pin_recovery_requests
  set status='code_sent',
      otp_hash=extensions.crypt(p_code,extensions.gen_salt('bf',10)),
      otp_expires_at=now()+interval '15 minutes',
      otp_attempts=0,
      approved_at=coalesce(approved_at,now()),
      sent_at=now(),
      updated_at=now()
  where id=r.id;

  insert into public.audit_log(action,details)
  values('admin_issue_pin_recovery_code',
         jsonb_build_object('request_id',r.id,'player_id',r.player_id,'expires_at',now()+interval '15 minutes'));

  return jsonb_build_object(
    'ok',true,
    'request_id',r.id,
    'name',pname,
    'phone',r.phone,
    'expires_at',now()+interval '15 minutes',
    'message','Código criado. Envie-o ao jogador por um canal confirmado.'
  );
end;
$$;

create or replace function public.jl_confirm_pin_recovery(
  p_phone text,
  p_email text,
  p_code text,
  p_new_pin text
)
returns jsonb language plpgsql security definer set search_path=public,extensions
as $$
declare
  v_phone text:=public.jl_phone(p_phone);
  v_email text:=lower(trim(coalesce(p_email,'')));
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
    and pr.recovery_email=v_email
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
$$;

-- INVARIANTES DO LUDO: não dependem da versão específica de uma RPC.
create or replace function public.jl_guard_ludo_room_member_funds()
returns trigger language plpgsql security definer set search_path=public
as $$
declare
  v_bet numeric;
  v_status text;
begin
  select bet_amount,status into v_bet,v_status
  from public.ludo_rooms
  where id=new.room_id;

  if v_status in ('waiting','negotiating') and coalesce(new.status,'active')<>'left' then
    perform public.jl_require_cash_balance(new.player_id,v_bet);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_jl_guard_ludo_room_member_funds on public.ludo_room_players;
create trigger trg_jl_guard_ludo_room_member_funds
before insert on public.ludo_room_players
for each row execute function public.jl_guard_ludo_room_member_funds();

create or replace function public.jl_guard_ludo_queue_funds()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
  perform public.jl_require_cash_balance(new.player_id,new.bet_amount);
  return new;
end;
$$;

drop trigger if exists trg_jl_guard_ludo_queue_funds on public.ludo_waiting_queue;
create trigger trg_jl_guard_ludo_queue_funds
before insert or update of bet_amount,player_id on public.ludo_waiting_queue
for each row execute function public.jl_guard_ludo_queue_funds();

-- Convites são efetivamente sem prazo, inclusive para funções legadas que testam expires_at > now().
create or replace function public.jl_persist_ludo_invite()
returns trigger language plpgsql set search_path=public
as $$
begin
  if new.status='pending' then new.expires_at:='infinity'::timestamptz; end if;
  return new;
end;
$$;

drop trigger if exists trg_jl_persist_ludo_invite on public.ludo_invitations;
create trigger trg_jl_persist_ludo_invite
before insert or update of status,expires_at on public.ludo_invitations
for each row execute function public.jl_persist_ludo_invite();

update public.ludo_invitations
set expires_at='infinity'::timestamptz
where status='pending';

create or replace function public.jl_persist_ludo_room_waiting()
returns trigger language plpgsql set search_path=public
as $$
begin
  if new.status='negotiating' then
    new.action_deadline:=null;
  end if;
  if new.is_public and new.status in ('waiting','negotiating') then
    new.public_challenge_expires_at:='infinity'::timestamptz;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_jl_persist_ludo_room_waiting on public.ludo_rooms;
create trigger trg_jl_persist_ludo_room_waiting
before insert or update of status,is_public,action_deadline,public_challenge_expires_at
on public.ludo_rooms
for each row execute function public.jl_persist_ludo_room_waiting();

update public.ludo_rooms
set action_deadline=null,
    public_challenge_expires_at=case
      when is_public and status in ('waiting','negotiating') then 'infinity'::timestamptz
      else public_challenge_expires_at
    end
where status='negotiating'
   or (is_public and status in ('waiting','negotiating'));

-- Reentrada deve sempre contar para a obrigação de apostar depósitos, mesmo se uma RPC antiga regressar.
create or replace function public.jl_guard_ludo_reentry_wager()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
  if new.kind='ludo_reentry'
     and new.amount<0
     and new.reference_id is not null
     and not exists(
       select 1 from public.deposit_wager_usages u
       where u.player_id=new.player_id
         and u.source_type='ludo_reentry'
         and u.reference_id=new.reference_id
     ) then
    perform public.jl_apply_cash_wager(
      new.player_id,
      abs(new.amount),
      'ludo_reentry',
      new.reference_id
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_jl_guard_ludo_reentry_wager on public.transactions;
create trigger trg_jl_guard_ludo_reentry_wager
after insert on public.transactions
for each row execute function public.jl_guard_ludo_reentry_wager();

-- CONTADORES ADMINISTRATIVOS: baseline permite "zerar" painel sem apagar dinheiro nem histórico.
create table if not exists public.admin_metric_baselines (
  id smallint primary key default 1 check (id=1),
  number_total numeric not null default 0,
  pair_total numeric not null default 0,
  ludo_total numeric not null default 0,
  reset_at timestamptz not null default now()
);
alter table public.admin_metric_baselines enable row level security;
insert into public.admin_metric_baselines(id) values(1) on conflict(id) do nothing;

create or replace function public.jl_admin_financial_summary(p_token text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare
  b public.admin_metric_baselines%rowtype;
  v_users numeric:=0;
  v_number_raw numeric:=0;
  v_pair_raw numeric:=0;
  v_ludo_raw numeric:=0;
  v_number numeric:=0;
  v_pair numeric:=0;
  v_ludo numeric:=0;
begin
  perform public.jl_require_admin(p_token);
  select * into b from public.admin_metric_baselines where id=1;

  select coalesce(sum(balance),0) into v_users
  from public.players where deleted_at is null;

  select coalesce(sum(amount),0) into v_number_raw from public.bets;
  select coalesce(sum(amount),0) into v_pair_raw from public.pair_bets;
  select coalesce(-sum(amount) filter(where amount<0),0) into v_ludo_raw
  from public.transactions
  where kind in ('ludo_stake','ludo_reentry');

  v_number:=greatest(0,v_number_raw-coalesce(b.number_total,0));
  v_pair:=greatest(0,v_pair_raw-coalesce(b.pair_total,0));
  v_ludo:=greatest(0,v_ludo_raw-coalesce(b.ludo_total,0));

  return jsonb_build_object(
    'user_balance_total',round(v_users,2),
    'number_total',round(v_number,2),
    'pair_total',round(v_pair,2),
    'ludo_total',round(v_ludo,2),
    'games_total',round(v_number+v_pair+v_ludo,2),
    'since',b.reset_at
  );
end;
$$;

create or replace function public.jl_admin_reset_financial_counters(
  p_token text,
  p_admin_pin text
)
returns jsonb language plpgsql security definer set search_path=public,extensions
as $$
declare
  v_hash text;
  v_number numeric:=0;
  v_pair numeric:=0;
  v_ludo numeric:=0;
begin
  perform public.jl_require_admin(p_token);
  select code_hash into v_hash from public.admin_config order by id limit 1;
  if v_hash is null
     or encode(extensions.digest(coalesce(p_admin_pin,''),'sha256'),'hex')<>v_hash then
    raise exception 'PIN administrativo incorreto.';
  end if;

  select coalesce(sum(amount),0) into v_number from public.bets;
  select coalesce(sum(amount),0) into v_pair from public.pair_bets;
  select coalesce(-sum(amount) filter(where amount<0),0) into v_ludo
  from public.transactions where kind in ('ludo_stake','ludo_reentry');

  insert into public.admin_metric_baselines(id,number_total,pair_total,ludo_total,reset_at)
  values(1,v_number,v_pair,v_ludo,now())
  on conflict(id) do update set
    number_total=excluded.number_total,
    pair_total=excluded.pair_total,
    ludo_total=excluded.ludo_total,
    reset_at=excluded.reset_at;

  insert into public.audit_log(action,details)
  values('admin_reset_financial_counters',
         jsonb_build_object('number_baseline',v_number,'pair_baseline',v_pair,'ludo_baseline',v_ludo,'at',now()));

  return jsonb_build_object('ok',true,'message','Contadores dos jogos zerados. Saldos e histórico foram preservados.');
end;
$$;

create or replace function public.jl_admin_force_logout_player(
  p_token text,
  p_player_id uuid
)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_count integer:=0;
begin
  perform public.jl_require_admin(p_token);
  if not exists(select 1 from public.players where id=p_player_id and deleted_at is null) then
    raise exception 'Jogador não encontrado.';
  end if;
  delete from public.player_sessions where player_id=p_player_id;
  get diagnostics v_count=row_count;
  insert into public.audit_log(action,details)
  values('admin_force_logout_player',jsonb_build_object('player_id',p_player_id,'sessions',v_count,'at',now()));
  return jsonb_build_object('ok',true,'sessions_closed',v_count,'message','Sessões do jogador encerradas.');
end;
$$;

create or replace function public.jl_admin_delete_player(
  p_token text,
  p_player_id uuid,
  p_admin_pin text
)
returns jsonb language plpgsql security definer set search_path=public,extensions
as $$
declare
  v_hash text;
  v_name text;
begin
  perform public.jl_require_admin(p_token);
  select code_hash into v_hash from public.admin_config order by id limit 1;
  if v_hash is null
     or encode(extensions.digest(coalesce(p_admin_pin,''),'sha256'),'hex')<>v_hash then
    raise exception 'PIN administrativo incorreto.';
  end if;

  select name into v_name
  from public.players
  where id=p_player_id and deleted_at is null
  for update;

  if v_name is null then raise exception 'Jogador não encontrado.'; end if;

  if exists(
    select 1
    from public.ludo_room_players rp
    join public.ludo_rooms r on r.id=rp.room_id
    where rp.player_id=p_player_id
      and rp.status<>'left'
      and r.status in ('funding','playing')
  ) then
    raise exception 'O jogador está numa partida de Ludo ativa. Cancele/termine a partida antes de eliminar a conta.';
  end if;

  delete from public.player_sessions where player_id=p_player_id;
  delete from public.customer_support_messages where player_id=p_player_id;
  update public.pin_recovery_requests
    set status='cancelled',otp_hash=null,otp_expires_at=null,updated_at=now()
  where player_id=p_player_id and status in ('pending_admin','sending','code_sent');

  update public.ludo_waiting_queue set expires_at=now() where player_id=p_player_id;
  update public.ludo_invitations set status='cancelled'
  where target_player_id=p_player_id and status='pending';

  update public.players
  set name='Conta eliminada',
      phone='deleted-'||replace(id::text,'-',''),
      pin_hash=extensions.crypt(encode(extensions.gen_random_bytes(24),'hex'),extensions.gen_salt('bf',10)),
      blocked=true,
      deleted_at=now(),
      deleted_by_admin=true,
      updated_at=now()
  where id=p_player_id;

  insert into public.audit_log(action,details)
  values('admin_delete_player',
         jsonb_build_object('player_id',p_player_id,'previous_name',v_name,'at',now(),'mode','anonymized_preserve_financial_audit'));

  return jsonb_build_object(
    'ok',true,
    'message','Conta eliminada e anonimizada. O histórico financeiro foi preservado para auditoria.'
  );
end;
$$;

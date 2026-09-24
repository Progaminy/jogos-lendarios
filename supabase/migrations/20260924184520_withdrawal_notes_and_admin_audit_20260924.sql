alter table public.withdrawal_requests
  add column if not exists user_note text not null default '';

create or replace function public.jl_request_withdrawal(
  p_token text,
  p_amount numeric,
  p_note text default ''
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_player public.players%rowtype;
  v_id uuid;
  v_locked numeric:=0;
  v_withdrawable numeric:=0;
  v_note text:=left(trim(coalesce(p_note,'')),160);
begin
  if p_amount is null or p_amount<1 or p_amount>1000000 then
    raise exception 'Valor de saque inválido.';
  end if;
  select * into v_player from public.players where id=v_player_id and deleted_at is null for update;
  if v_player.id is null then raise exception 'Conta indisponível.'; end if;
  v_locked:=public.jl_deposit_wager_locked(v_player_id);
  v_withdrawable:=greatest(0,v_player.balance-v_locked);
  if p_amount>v_withdrawable then
    insert into public.withdrawal_requests(player_id,amount,status,reason,user_note,reviewed_at)
    values(v_player_id,round(p_amount,2),'rejected',
      case when v_player.balance<p_amount then 'Saldo insuficiente' else 'Depósito ainda não foi jogado' end,
      v_note,now()) returning id into v_id;
    return jsonb_build_object('ok',false,'request_id',v_id,'status','rejected','message',
      case when v_player.balance<p_amount then 'Saque rejeitado automaticamente: saldo insuficiente.'
      else 'Saque bloqueado: parte do saldo vem de depósito que ainda precisa ser jogado.' end,
      'balance',v_player.balance,'deposit_locked',v_locked,'withdrawable_balance',v_withdrawable);
  end if;
  update public.players set balance=balance-round(p_amount,2),updated_at=now() where id=v_player_id;
  insert into public.withdrawal_requests(player_id,amount,status,user_note)
  values(v_player_id,round(p_amount,2),'pending',v_note) returning id into v_id;
  insert into public.transactions(player_id,kind,amount,status,reference_id,note)
  values(v_player_id,'withdrawal',-round(p_amount,2),'pending',v_id,
    case when v_note='' then 'Valor reservado para saque' else 'Valor reservado para saque · mensagem: '||v_note end);
  return jsonb_build_object('ok',true,'request_id',v_id,'status','pending','message','Pedido de saque enviado para autorização.',
    'balance',v_player.balance-round(p_amount,2),'deposit_locked',v_locked,'withdrawable_balance',v_withdrawable-round(p_amount,2));
end;
$$;

create or replace function public.jl_admin_dashboard(p_token text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_number jsonb;v_pair jsonb;v_deposits jsonb;v_withdrawals jsonb;v_players jsonb;
begin
  perform public.jl_require_admin(p_token);perform public.jl_process_game_engine();
  v_number:=public.jl_admin_game_snapshot('number');v_pair:=public.jl_admin_game_snapshot('pair');
  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_deposits from (
    select d.id,d.amount,d.note,d.status,d.created_at,p.name,p.phone from public.deposit_requests d join public.players p on p.id=d.player_id where d.status='pending' order by d.created_at desc limit 100) x;
  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_withdrawals from (
    select w.id,w.amount,w.status,w.reason,w.user_note,w.created_at,p.name,p.phone,
      public.jl_deposit_wager_locked(w.player_id) deposit_locked,
      greatest(0,p.balance-public.jl_deposit_wager_locked(w.player_id)) withdrawable_balance
    from public.withdrawal_requests w join public.players p on p.id=w.player_id
    where w.status='pending' and p.deleted_at is null order by w.created_at desc limit 100) x;
  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_players from (
    select p.id,p.name,p.phone,p.balance,p.blocked,p.created_at,
      public.jl_deposit_wager_locked(p.id) deposit_locked,
      greatest(0,p.balance-public.jl_deposit_wager_locked(p.id)) withdrawable_balance
    from public.players p where p.deleted_at is null order by p.created_at desc limit 200) x;
  return jsonb_build_object('server_time',now(),'games',jsonb_build_object('number',v_number,'pair',v_pair),
    'pending_deposits',v_deposits,'pending_withdrawals',v_withdrawals,'players',v_players);
end;
$$;

create or replace function public.jl_admin_recent_audit(p_token text,p_limit integer default 80)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_limit integer:=least(200,greatest(1,coalesce(p_limit,80)));v_rows jsonb;
begin
  perform public.jl_require_admin(p_token);
  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_rows
  from (select id,action,details,created_at from public.audit_log order by created_at desc limit v_limit) x;
  return v_rows;
end;
$$;

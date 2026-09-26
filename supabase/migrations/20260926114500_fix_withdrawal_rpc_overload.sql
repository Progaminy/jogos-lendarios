-- Remove the ambiguous PostgREST overload introduced by the optional note parameter.
-- Withdrawal messages are no longer collected from players, so keep one canonical RPC.

drop function if exists public.jl_request_withdrawal(text,numeric,text);

create or replace function public.jl_request_withdrawal(
  p_token text,
  p_amount numeric
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
begin
  if p_amount is null or p_amount<1 or p_amount>1000000 then
    raise exception 'Valor de saque inválido.';
  end if;

  select *
  into v_player
  from public.players
  where id=v_player_id
    and deleted_at is null
  for update;

  if v_player.id is null then
    raise exception 'Conta indisponível.';
  end if;

  v_locked:=public.jl_deposit_wager_locked(v_player_id);
  v_withdrawable:=greatest(0,v_player.balance-v_locked);

  if p_amount>v_withdrawable then
    insert into public.withdrawal_requests(
      player_id,amount,status,reason,reviewed_at
    )
    values(
      v_player_id,
      round(p_amount,2),
      'rejected',
      case
        when v_player.balance<p_amount then 'Saldo insuficiente'
        else 'Depósito ainda não foi jogado'
      end,
      now()
    )
    returning id into v_id;

    return jsonb_build_object(
      'ok',false,
      'request_id',v_id,
      'status','rejected',
      'message',
        case
          when v_player.balance<p_amount then 'Saque rejeitado automaticamente: saldo insuficiente.'
          else 'Saque bloqueado: parte do saldo vem de depósito que ainda precisa ser jogado.'
        end,
      'balance',v_player.balance,
      'deposit_locked',v_locked,
      'withdrawable_balance',v_withdrawable
    );
  end if;

  update public.players
  set balance=balance-round(p_amount,2),
      updated_at=now()
  where id=v_player_id;

  insert into public.withdrawal_requests(player_id,amount,status)
  values(v_player_id,round(p_amount,2),'pending')
  returning id into v_id;

  insert into public.transactions(
    player_id,kind,amount,status,reference_id,note
  )
  values(
    v_player_id,
    'withdrawal',
    -round(p_amount,2),
    'pending',
    v_id,
    'Valor reservado para saque'
  );

  return jsonb_build_object(
    'ok',true,
    'request_id',v_id,
    'status','pending',
    'message','Pedido de saque enviado para autorização.',
    'balance',v_player.balance-round(p_amount,2),
    'deposit_locked',v_locked,
    'withdrawable_balance',v_withdrawable-round(p_amount,2)
  );
end;
$$;

revoke execute on function public.jl_request_withdrawal(text,numeric) from public, authenticated;
grant execute on function public.jl_request_withdrawal(text,numeric) to anon, service_role;

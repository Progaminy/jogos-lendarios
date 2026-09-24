create or replace function public.jl_admin_review_withdrawal(
  p_token text,
  p_request_id uuid,
  p_decision text
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_req public.withdrawal_requests%rowtype;
  v_player public.players%rowtype;
  v_locked numeric:=0;
  v_available_before_reservation numeric:=0;
  v_effective_decision text:=p_decision;
  v_reason text;
begin
  perform public.jl_require_admin(p_token);

  if p_decision not in ('approved','rejected') then
    raise exception 'Decisão inválida.';
  end if;

  select * into v_req
  from public.withdrawal_requests
  where id=p_request_id
  for update;

  if v_req.id is null or v_req.status<>'pending' then
    raise exception 'Pedido de saque não está pendente.';
  end if;

  select * into v_player
  from public.players
  where id=v_req.player_id
  for update;

  v_locked:=public.jl_deposit_wager_locked(v_req.player_id);
  v_available_before_reservation:=greatest(
    0,
    (v_player.balance+v_req.amount)-v_locked
  );

  if p_decision='approved' and v_req.amount>v_available_before_reservation then
    v_effective_decision:='rejected';
    v_reason:='Rejeitado: existe depósito ainda não jogado.';
  elsif p_decision='rejected' then
    v_reason:='Rejeitado pelo administrador';
  end if;

  update public.withdrawal_requests
  set status=v_effective_decision,
      reviewed_at=now(),
      reason=case
        when v_effective_decision='rejected' then v_reason
        else reason
      end
  where id=v_req.id;

  update public.transactions
  set status=case when v_effective_decision='approved' then 'completed' else 'rejected' end
  where reference_id=v_req.id
    and kind='withdrawal'
    and status='pending';

  if v_effective_decision='rejected' then
    update public.players
    set balance=balance+v_req.amount,updated_at=now()
    where id=v_req.player_id;

    insert into public.transactions(
      player_id,kind,amount,status,reference_id,note
    ) values(
      v_req.player_id,'withdrawal_refund',v_req.amount,'completed',v_req.id,
      case
        when p_decision='approved' then
          'Saque bloqueado: depósito ainda precisa ser jogado'
        else
          'Saque rejeitado: valor devolvido ao saldo'
      end
    );
  end if;

  return jsonb_build_object(
    'ok',true,
    'status',v_effective_decision,
    'requested_decision',p_decision,
    'request_id',v_req.id,
    'deposit_locked',v_locked,
    'available_before_reservation',v_available_before_reservation,
    'message',
      case
        when p_decision='approved' and v_effective_decision='rejected'
          then 'Saque não aprovado: o jogador ainda tem depósito por jogar.'
        when v_effective_decision='approved'
          then 'Saque aprovado.'
        else 'Saque rejeitado.'
      end
  );
end;
$$;

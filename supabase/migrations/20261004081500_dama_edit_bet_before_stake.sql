-- Dama Lendária — o criador pode ajustar o valor antes de qualquer débito.
-- Se o adversário já tinha aceite o valor anterior, a sala volta para
-- negociação para exigir nova aceitação do valor atualizado.

create or replace function public.jl_dama_update_bet_before_stake(
  p_token text,
  p_room uuid,
  p_bet_amount numeric
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.dama_rooms%rowtype;
begin
  select * into r
  from public.dama_rooms
  where id=p_room
  for update;

  if r.id is null then
    raise exception 'Sala de Dama não encontrada.';
  end if;
  if r.host_id<>me then
    raise exception 'Apenas o criador pode alterar o valor da aposta.';
  end if;
  if r.status not in ('waiting','negotiating','funding') then
    raise exception 'O valor da aposta já está bloqueado.';
  end if;
  if p_bet_amount is null or p_bet_amount<10 or p_bet_amount<>trunc(p_bet_amount) then
    raise exception 'A aposta deve ser um valor inteiro de pelo menos 10 MZN.';
  end if;
  if exists(
    select 1
    from public.dama_room_players rp
    where rp.room_id=p_room
      and rp.status<>'left'
      and rp.stake_paid
  ) then
    raise exception 'O valor não pode mudar depois de uma aposta confirmada.';
  end if;

  if r.bet_amount=p_bet_amount then
    return public.jl_dama_room_state(p_token,p_room);
  end if;

  update public.dama_rooms
  set bet_amount=p_bet_amount,
      status=case when guest_id is null then 'waiting' else 'negotiating' end,
      updated_at=now()
  where id=p_room;

  update public.dama_room_players
  set settings_accepted=(seat=1),
      stake_amount=null
  where room_id=p_room and status<>'left';

  perform public.jl_dama_event(
    p_room,me,'bet_amount_changed',
    jsonb_build_object('old_bet_amount',r.bet_amount,'bet_amount',p_bet_amount)
  );

  return public.jl_dama_room_state(p_token,p_room);
end;
$$;

revoke all on function public.jl_dama_update_bet_before_stake(text,uuid,numeric)
from public,anon,authenticated;
grant execute on function public.jl_dama_update_bet_before_stake(text,uuid,numeric)
to anon,authenticated;

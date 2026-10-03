-- Dama Lendária — não criar transação financeira de valor zero.
-- Em partidas normais o pot é positivo; esta guarda mantém o encerramento robusto
-- mesmo diante de estado administrativo/teste sem pot.

create or replace function public.jl_dama_finish_win(
  p_room uuid,p_winner uuid,p_reason text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  r public.dama_rooms%rowtype;
  gross numeric;
  comm numeric:=0;
  net numeric:=0;
  payout_id uuid;
begin
  select * into r from public.dama_rooms where id=p_room for update;
  if r.status in ('finished','cancelled') then return; end if;
  if not public.jl_dama_is_member(p_room,p_winner) then
    raise exception 'Vencedor inválido.';
  end if;

  gross:=round(coalesce(r.pot,0),2);

  if gross>0 then
    comm:=least(gross,greatest(1,ceil(gross*0.01)));
    net:=gross-comm;

    insert into public.dama_payouts(
      room_id,player_id,gross_amount,commission,net_amount
    )
    values(p_room,p_winner,gross,comm,net)
    on conflict(room_id,player_id) do nothing
    returning id into payout_id;

    if payout_id is not null and net>0 then
      perform public.jl_lock_player_wallet(p_winner);
      update public.players
      set balance=balance+net,updated_at=now()
      where id=p_winner;

      insert into public.transactions(
        player_id,kind,amount,status,reference_id,note
      )
      values(
        p_winner,'dama_payout',net,'completed',p_room,
        'Prémio Dama líquido; comissão '||comm||' MZN'
      );
    end if;
  end if;

  update public.dama_room_players
  set status=case when player_id=p_winner then 'finished' else status end
  where room_id=p_room;

  update public.dama_rooms
  set status='finished',
      winner_player_id=p_winner,
      result_reason=p_reason,
      commission_total=comm,
      action_deadline=null,
      finished_at=now(),
      updated_at=now()
  where id=p_room;

  perform public.jl_dama_event(
    p_room,p_winner,'game_finished',
    jsonb_build_object(
      'winner_player_id',p_winner,
      'reason',p_reason,
      'pot',gross,
      'commission',comm
    )
  );
end;
$$;

revoke all on function public.jl_dama_finish_win(uuid,uuid,text)
from public,anon,authenticated;

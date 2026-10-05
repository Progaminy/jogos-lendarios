create or replace function public.jl_ludo_refund_room(p_room uuid, p_note text default 'Reembolso Ludo')
returns void
language plpgsql
security definer
set search_path = 'public'
as $$
declare x record; restored numeric;
begin
  perform 1 from public.ludo_rooms where id=p_room for update;
  for x in select * from public.ludo_room_players where room_id=p_room and stake_paid order by seat for update
  loop
    if coalesce(x.stake_amount,0)>0 then
      perform public.jl_lock_player_wallet(x.player_id);
      update public.players set balance=balance+x.stake_amount,updated_at=now() where id=x.player_id;
      restored:=public.jl_reverse_cash_wager(x.player_id,'ludo_stake',p_room);
      insert into public.transactions(player_id,kind,amount,status,reference_id,note)
      values(x.player_id,'ludo_refund',x.stake_amount,'completed',p_room,p_note||' · '||restored||' MZN voltaram a ficar bloqueados até serem jogados');
    end if;
  end loop;
  update public.ludo_room_players set stake_paid=false,stake_amount=0 where room_id=p_room and stake_paid;
  update public.ludo_rooms set pot=0,updated_at=now() where id=p_room;
end;
$$;

create or replace function public.jl_dama_refund_room(p_room uuid, p_note text default 'Reembolso Dama')
returns void
language plpgsql
security definer
set search_path = 'public'
as $$
declare x record; restored numeric;
begin
  perform 1 from public.dama_rooms where id=p_room for update;
  for x in select * from public.dama_room_players where room_id=p_room and stake_paid order by seat for update
  loop
    if coalesce(x.stake_amount,0)>0 then
      perform public.jl_lock_player_wallet(x.player_id);
      update public.players set balance=balance+x.stake_amount,updated_at=now() where id=x.player_id;
      restored:=public.jl_reverse_cash_wager(x.player_id,'dama_stake',p_room);
      insert into public.transactions(player_id,kind,amount,status,reference_id,note)
      values(x.player_id,'dama_refund',x.stake_amount,'completed',p_room,p_note||' · '||restored||' MZN voltaram a ficar bloqueados até serem jogados');
    end if;
  end loop;
  update public.dama_room_players set stake_paid=false,stake_amount=0 where room_id=p_room and stake_paid;
  update public.dama_rooms set pot=0,updated_at=now() where id=p_room;
end;
$$;

create or replace function public.jl_dama_update_settings(
  p_token text,p_room uuid,p_bet_amount numeric,p_turn_seconds integer,p_host_color text,p_first_player text,p_is_public boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.dama_rooms%rowtype;
  v_color text:=lower(trim(coalesce(p_host_color,'')));
  v_first text:=lower(trim(coalesce(p_first_player,'')));
  v_bet numeric;
begin
  select * into r from public.dama_rooms where id=p_room for update;
  if r.id is null or r.host_id<>me then raise exception 'Apenas o criador pode alterar a partida.'; end if;
  if r.status not in ('waiting','negotiating') then raise exception 'As definições já estão bloqueadas.'; end if;
  if r.play_mode='free' then
    perform public.jl_free_access_require(me);
    v_bet:=0;
  else
    if p_bet_amount is null or p_bet_amount<10 or p_bet_amount<>trunc(p_bet_amount) then raise exception 'A aposta deve ser um valor inteiro de pelo menos 10 MZN.'; end if;
    v_bet:=p_bet_amount;
  end if;
  if not public.jl_dama_turn_seconds_allowed(p_turn_seconds) then raise exception 'Tempo de jogada não permitido. Atualize a Dama e escolha um dos tempos disponíveis.'; end if;
  if v_color not in ('white','red') then raise exception 'Cor inválida.'; end if;
  if v_first not in ('host','guest') then raise exception 'Quem começa é inválido.'; end if;
  update public.dama_rooms
  set bet_amount=v_bet,turn_seconds=p_turn_seconds,host_color=v_color,first_player_choice=v_first,
      is_public=coalesce(p_is_public,false),status=case when guest_id is null then 'waiting' else 'negotiating' end,updated_at=now()
  where id=p_room;
  update public.dama_room_players rp
  set color=case when rp.seat=1 then v_color else case v_color when 'white' then 'red' else 'white' end end,
      settings_accepted=(rp.seat=1),
      stake_paid=case when r.play_mode='free' and rp.seat=1 then true when r.play_mode='free' then false else rp.stake_paid end,
      stake_amount=case when r.play_mode='free' then 0 else rp.stake_amount end
  where rp.room_id=p_room and rp.status<>'left';
  perform public.jl_dama_event(p_room,me,'settings_changed',jsonb_build_object('bet_amount',v_bet,'turn_seconds',p_turn_seconds,'host_color',v_color,'first_player',v_first,'free',r.play_mode='free'));
  return public.jl_dama_room_state(p_token,p_room);
end;
$$;

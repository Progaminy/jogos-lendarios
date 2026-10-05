create or replace function public.jl_ludo_finish_room(p_room uuid, p_winner uuid, p_team integer)
returns void
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  r public.ludo_rooms%rowtype;
  gross numeric;
  comm numeric;
  net numeric;
  x record;
  total_comm numeric:=0;
  v_payout_id uuid;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.status='finished' then return; end if;

  if r.mode='solo' then
    if p_winner is null then raise exception 'Vencedor inválido.'; end if;
    gross:=round(coalesce(r.pot,0),2);
    if gross>0 then
      comm:=least(gross,greatest(1,ceil(gross*0.01)));
      net:=gross-comm;
      v_payout_id:=null;
      insert into public.ludo_payouts(room_id,player_id,gross_amount,commission,net_amount)
      values(p_room,p_winner,gross,comm,net)
      on conflict(room_id,player_id) do nothing returning id into v_payout_id;
      if v_payout_id is not null and net>0 then
        perform public.jl_lock_player_wallet(p_winner);
        update public.players set balance=balance+net,updated_at=now() where id=p_winner;
        insert into public.transactions(player_id,kind,amount,status,reference_id,note)
        values(p_winner,'ludo_payout',net,'completed',p_room,'Prémio Ludo líquido; comissão '||comm||' MZN');
      elsif v_payout_id is null then
        select commission into comm from public.ludo_payouts where room_id=p_room and player_id=p_winner;
      end if;
      total_comm:=coalesce(comm,0);
    else
      total_comm:=0;
    end if;
    update public.ludo_room_players
    set status=case when player_id=p_winner then 'finished' else status end
    where room_id=p_room;
  else
    if p_team not in (1,2) then raise exception 'Equipa vencedora inválida.'; end if;
    gross:=round(coalesce(r.pot,0)/2,2);
    if gross>0 then
      for x in select player_id from public.ludo_room_players where room_id=p_room and team=p_team order by seat
      loop
        comm:=least(gross,greatest(1,ceil(gross*0.01)));
        net:=gross-comm;
        v_payout_id:=null;
        insert into public.ludo_payouts(room_id,player_id,gross_amount,commission,net_amount)
        values(p_room,x.player_id,gross,comm,net)
        on conflict(room_id,player_id) do nothing returning id into v_payout_id;
        if v_payout_id is not null and net>0 then
          perform public.jl_lock_player_wallet(x.player_id);
          update public.players set balance=balance+net,updated_at=now() where id=x.player_id;
          insert into public.transactions(player_id,kind,amount,status,reference_id,note)
          values(x.player_id,'ludo_payout',net,'completed',p_room,'Prémio Ludo parceiros líquido; comissão individual '||comm||' MZN');
        elsif v_payout_id is null then
          select commission into comm from public.ludo_payouts where room_id=p_room and player_id=x.player_id;
        end if;
        total_comm:=total_comm+coalesce(comm,0);
      end loop;
    else
      total_comm:=0;
    end if;
  end if;

  update public.ludo_rooms
  set status='finished',winner_player_id=p_winner,winner_team=p_team,
      commission_total=total_comm,turn_phase=null,dice_result=null,
      action_deadline=null,finished_at=now(),updated_at=now()
  where id=p_room;
  perform public.jl_ludo_event(p_room,p_winner,'game_finished',jsonb_build_object(
    'winner_player_id',p_winner,'winner_team',p_team,'pot',r.pot,
    'commission_total',total_comm,'free',r.play_mode='free'));
end;
$$;

create or replace function public.jl_ludo_propose_bet(p_token text, p_room uuid, p_bet_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  had_paid boolean:=false;
  current_reentry numeric:=10;
  stake_secs integer:=60;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.id is null or not public.jl_ludo_is_member(p_room,me) then raise exception 'Sala indisponível.'; end if;
  if r.play_mode='free' then raise exception 'Partida FREE não usa apostas.'; end if;
  if r.status<>'funding' then raise exception 'O valor só pode ser negociado antes do início da partida.'; end if;
  if p_bet_amount is null or p_bet_amount<10 or p_bet_amount<>trunc(p_bet_amount) then raise exception 'O valor deve ser inteiro e no mínimo 10 MZN.'; end if;
  if p_bet_amount=r.bet_amount then return public.jl_ludo_room_state(p_token,p_room); end if;
  current_reentry:=coalesce(nullif(r.rules->>'reentry_amount','')::numeric,10);
  if current_reentry>p_bet_amount then raise exception 'O valor proposto não pode ficar abaixo do valor de reentrada atual (% MZN).',current_reentry; end if;
  select exists(select 1 from public.ludo_room_players where room_id=p_room and status<>'left' and stake_paid) into had_paid;
  if had_paid then
    perform public.jl_ludo_refund_room(p_room,'Reembolso: novo valor proposto antes do início do Ludo');
  else
    update public.ludo_room_players set stake_paid=false,stake_amount=0 where room_id=p_room and status<>'left';
    update public.ludo_rooms set pot=0 where id=p_room;
  end if;
  stake_secs:=greatest(30,least(coalesce(nullif(r.rules->>'stake_seconds','')::integer,60),300));
  update public.ludo_rooms set bet_amount=p_bet_amount,status='funding',action_deadline=now()+make_interval(secs=>stake_secs),updated_at=now() where id=p_room;
  perform public.jl_ludo_event(p_room,me,'bet_proposed',jsonb_build_object('old_amount',r.bet_amount,'amount',p_bet_amount,'proposed_by',me,'refunded_previous_acceptances',had_paid));
  return public.jl_ludo_room_state(p_token,p_room);
end;
$$;

create or replace function public.jl_ludo_join_public_room(p_token text,p_code text)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare me uuid:=public.jl_player_id(p_token); rid uuid;
begin
  select r.id into rid
  from public.ludo_rooms r
  where upper(r.code)=upper(trim(p_code))
    and r.play_mode='bet'
    and r.is_public
    and r.status in ('waiting','negotiating')
    and exists(select 1 from public.ludo_room_players host_rp where host_rp.room_id=r.id and host_rp.player_id=r.host_id and host_rp.status<>'left')
    and exists(select 1 from public.player_sessions ps where ps.player_id=r.host_id and ps.expires_at>now() and ps.last_seen_at>=now()-interval '30 seconds');
  if rid is null then raise exception 'Sala pública não encontrada.'; end if;
  perform public.jl_ludo_join_room_internal(rid,me);
  delete from public.ludo_waiting_queue where player_id=me;
  return public.jl_ludo_room_state(p_token,rid);
end;
$$;

alter table public.ludo_rooms drop constraint if exists ludo_rooms_bet_amount_check;
alter table public.ludo_rooms add constraint ludo_rooms_bet_amount_check check (bet_amount >= 10);

alter table public.ludo_waiting_queue drop constraint if exists ludo_waiting_queue_bet_amount_check;
alter table public.ludo_waiting_queue add constraint ludo_waiting_queue_bet_amount_check check (bet_amount >= 10);

create or replace function public.jl_ludo_rules(p_rules jsonb, p_bet numeric)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  r jsonb := public.jl_ludo_defaults() || coalesce(p_rules,'{}'::jsonb);
  n numeric;
begin
  if (r->>'turn_seconds')::integer not between 30 and 120 then raise exception 'Tempo de jogada deve estar entre 30 e 120 segundos.'; end if;
  if (r->>'move_seconds')::integer not between 15 and 60 then raise exception 'Tempo para escolher a peça deve estar entre 15 e 60 segundos.'; end if;
  if (r->>'rules_response_seconds')::integer not between 30 and 60 then raise exception 'Tempo de resposta das regras deve estar entre 30 e 60 segundos.'; end if;
  if (r->>'stake_seconds')::integer not between 30 and 60 then raise exception 'Tempo para confirmar aposta deve estar entre 30 e 60 segundos.'; end if;
  if (r->>'invite_seconds')::integer not between 30 and 60 then raise exception 'Tempo de convite deve estar entre 30 e 60 segundos.'; end if;
  if (r->>'reentry_seconds')::integer not between 30 and 60 then raise exception 'Tempo de reentrada deve estar entre 30 e 60 segundos.'; end if;
  if (r->>'idle_strikes_limit')::integer not between 1 and 5 then raise exception 'Limite de ausências deve estar entre 1 e 5.'; end if;
  if r->>'capture_penalty' not in ('lose_turn','eliminate','eliminate_reentry') then raise exception 'Penalização de captura obrigatória inválida.'; end if;
  if r->>'base_exit_rule' not in ('six','one_or_six') then raise exception 'Regra de saída da base inválida.'; end if;
  n := (r->>'reentry_amount')::numeric;
  if n < 10 or n > p_bet then raise exception 'Valor de reentrada deve ficar entre 10 MZN e a aposta da sala.'; end if;
  return r;
end;
$$;

create or replace function public.jl_ludo_create_room(
  p_token text,
  p_player_count integer,
  p_bet_amount numeric,
  p_mode text default 'solo',
  p_is_public boolean default false,
  p_rules jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_player uuid := public.jl_player_id(p_token);
  v_room public.ludo_rooms%rowtype;
  v_rules jsonb;
begin
  if p_player_count not between 2 and 4 then raise exception 'Ludo aceita 2, 3 ou 4 jogadores.'; end if;
  if p_mode not in ('solo','partners') then raise exception 'Modo inválido.'; end if;
  if p_mode='partners' and p_player_count<>4 then raise exception 'Modo parceiros requer 4 jogadores.'; end if;
  if p_bet_amount is null or p_bet_amount < 10 then raise exception 'A aposta mínima é 10 MZN.'; end if;
  if exists(
    select 1
    from public.ludo_room_players rp
    join public.ludo_rooms r on r.id=rp.room_id
    where rp.player_id=v_player
      and rp.status<>'left'
      and r.status in ('waiting','negotiating','funding','playing')
  ) then raise exception 'Você já participa de uma sala de Ludo ativa.'; end if;
  perform public.jl_ludo_ensure_code(v_player);
  v_rules := public.jl_ludo_rules(p_rules,p_bet_amount);
  insert into public.ludo_rooms(code,host_id,player_count,mode,bet_amount,is_public,rules,status,action_deadline)
  values(public.jl_ludo_room_code(),v_player,p_player_count,p_mode,round(p_bet_amount,2),p_is_public,v_rules,'waiting',now()+make_interval(secs=>(v_rules->>'rules_response_seconds')::integer))
  returning * into v_room;
  insert into public.ludo_room_players(room_id,player_id,seat,color,team,accepted_rules_version)
  values(v_room.id,v_player,1,'red',case when p_mode='partners' then 1 else null end,v_room.rules_version);
  perform public.jl_ludo_event(v_room.id,v_player,'room_created',jsonb_build_object('code',v_room.code,'bet',v_room.bet_amount,'players',v_room.player_count,'mode',v_room.mode));
  return public.jl_ludo_room_state(p_token,v_room.id);
end;
$$;

create or replace function public.jl_ludo_enter_queue(
  p_token text,
  p_bet_amount numeric,
  p_player_count integer,
  p_mode text default 'solo'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := public.jl_player_id(p_token);
begin
  if p_player_count not between 2 and 4 then raise exception 'Quantidade de jogadores inválida.'; end if;
  if p_mode not in ('solo','partners') or (p_mode='partners' and p_player_count<>4) then raise exception 'Modo inválido.'; end if;
  if p_bet_amount is null or p_bet_amount < 10 then raise exception 'A aposta mínima é 10 MZN.'; end if;
  if exists(
    select 1
    from public.ludo_room_players rp
    join public.ludo_rooms r on r.id=rp.room_id
    where rp.player_id=me
      and rp.status<>'left'
      and r.status in ('waiting','negotiating','funding','playing')
  ) then raise exception 'Você já participa de uma sala ativa.'; end if;
  perform public.jl_ludo_ensure_code(me);
  insert into public.ludo_waiting_queue(player_id,bet_amount,player_count,mode,joined_at,expires_at)
  values(me,round(p_bet_amount,2),p_player_count,p_mode,now(),now()+interval '15 minutes')
  on conflict(player_id) do update
  set bet_amount=excluded.bet_amount,player_count=excluded.player_count,mode=excluded.mode,joined_at=now(),expires_at=excluded.expires_at;
  return jsonb_build_object('ok',true,'code',public.jl_ludo_display_code(me),'expires_at',now()+interval '15 minutes');
end;
$$;

create or replace function public.jl_ludo_finish_room(p_room uuid, p_winner uuid, p_team integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ludo_rooms%rowtype;
  gross numeric;
  comm numeric;
  net numeric;
  x record;
  total_comm numeric:=0;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.status='finished' then return; end if;
  if r.mode='solo' then
    if p_winner is null then raise exception 'Vencedor inválido.'; end if;
    gross:=round(r.pot,2);
    comm:=least(gross,greatest(1,ceil(gross*0.01)));
    net:=gross-comm;
    update public.players set balance=balance+net,updated_at=now() where id=p_winner;
    insert into public.ludo_payouts(room_id,player_id,gross_amount,commission,net_amount)
    values(p_room,p_winner,gross,comm,net) on conflict do nothing;
    insert into public.transactions(player_id,kind,amount,status,reference_id,note)
    values(p_winner,'ludo_payout',net,'completed',p_room,'Prémio Ludo líquido; comissão '||comm||' MZN');
    total_comm:=comm;
    update public.ludo_room_players set status=case when player_id=p_winner then 'finished' else status end where room_id=p_room;
  else
    if p_team not in (1,2) then raise exception 'Equipa vencedora inválida.'; end if;
    gross:=round(r.pot/2,2);
    for x in select player_id from public.ludo_room_players where room_id=p_room and team=p_team order by seat loop
      comm:=least(gross,greatest(1,ceil(gross*0.01)));
      net:=gross-comm;
      update public.players set balance=balance+net,updated_at=now() where id=x.player_id;
      insert into public.ludo_payouts(room_id,player_id,gross_amount,commission,net_amount)
      values(p_room,x.player_id,gross,comm,net) on conflict do nothing;
      insert into public.transactions(player_id,kind,amount,status,reference_id,note)
      values(x.player_id,'ludo_payout',net,'completed',p_room,'Prémio Ludo parceiros líquido; comissão individual '||comm||' MZN');
      total_comm:=total_comm+comm;
    end loop;
  end if;
  update public.ludo_rooms
  set status='finished',winner_player_id=p_winner,winner_team=p_team,commission_total=total_comm,turn_phase=null,dice_result=null,action_deadline=null,finished_at=now(),updated_at=now()
  where id=p_room;
  perform public.jl_ludo_event(p_room,p_winner,'game_finished',jsonb_build_object('winner_player_id',p_winner,'winner_team',p_team,'pot',r.pot,'commission_total',total_comm));
end;
$$;

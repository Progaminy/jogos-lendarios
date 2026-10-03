-- Corrige atualização de definições da Dama e permite o mesmo jogador voltar a aceitar após recusar.
create or replace function public.jl_dama_update_settings(
  p_token text,p_room uuid,p_bet_amount numeric,p_turn_seconds integer,
  p_host_color text,p_first_player text,p_is_public boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.dama_rooms%rowtype;
  v_color text:=lower(trim(coalesce(p_host_color,'')));
  v_first text:=lower(trim(coalesce(p_first_player,'')));
begin
  select * into r from public.dama_rooms where id=p_room for update;
  if r.id is null or r.host_id<>me then raise exception 'Apenas o criador pode alterar a partida.'; end if;
  if r.status not in ('waiting','negotiating') then raise exception 'As definições já estão bloqueadas.'; end if;
  if p_bet_amount is null or p_bet_amount<10 or p_bet_amount<>trunc(p_bet_amount) then
    raise exception 'A aposta deve ser um valor inteiro de pelo menos 10 MZN.';
  end if;
  if p_turn_seconds not in (120,180) then raise exception 'O tempo deve ser 2 ou 3 minutos.'; end if;
  if v_color not in ('white','red') then raise exception 'Cor inválida.'; end if;
  if v_first not in ('host','guest') then raise exception 'Quem começa é inválido.'; end if;

  update public.dama_rooms
  set bet_amount=p_bet_amount,turn_seconds=p_turn_seconds,host_color=v_color,
      first_player_choice=v_first,is_public=coalesce(p_is_public,false),
      status=case when guest_id is null then 'waiting' else 'negotiating' end,
      updated_at=now()
  where id=p_room;

  update public.dama_room_players rp
  set color=case
        when rp.seat=1 then v_color
        else case v_color when 'white' then 'red' else 'white' end
      end,
      settings_accepted=(rp.seat=1)
  where rp.room_id=p_room and rp.status<>'left';

  perform public.jl_dama_event(
    p_room,me,'settings_changed',
    jsonb_build_object(
      'bet_amount',p_bet_amount,'turn_seconds',p_turn_seconds,
      'host_color',v_color,'first_player',v_first
    )
  );

  return public.jl_dama_room_state(p_token,p_room);
end;
$$;

create or replace function public.jl_dama_accept_settings(
  p_token text,p_room uuid,p_accept boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.dama_rooms%rowtype;
  rp public.dama_room_players%rowtype;
begin
  select * into r from public.dama_rooms where id=p_room for update;
  select * into rp from public.dama_room_players
  where room_id=p_room and player_id=me and status<>'left' for update;

  if r.id is null or rp.player_id is null or r.status<>'negotiating' then
    raise exception 'Partida indisponível para aceitação.';
  end if;
  if me=r.host_id then return public.jl_dama_room_state(p_token,p_room); end if;

  if not coalesce(p_accept,true) then
    delete from public.dama_room_players where room_id=p_room and player_id=me;
    update public.dama_rooms set guest_id=null,status='waiting',updated_at=now() where id=p_room;
    perform public.jl_dama_event(p_room,me,'settings_declined','{}'::jsonb);
    return jsonb_build_object('ok',true,'accepted',false);
  end if;

  update public.dama_room_players
  set settings_accepted=true
  where room_id=p_room and player_id=me;

  update public.dama_rooms set status='funding',updated_at=now() where id=p_room;

  perform public.jl_dama_event(
    p_room,me,'settings_accepted',
    jsonb_build_object(
      'bet_amount',r.bet_amount,'turn_seconds',r.turn_seconds,
      'host_color',r.host_color,'first_player',r.first_player_choice
    )
  );

  return public.jl_dama_room_state(p_token,p_room);
end;
$$;
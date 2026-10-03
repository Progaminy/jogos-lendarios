-- Liga o convite global à criação efetiva da partida escolhida.

create or replace function public.jl_dama_create_from_board_invite(
  p_token text,
  p_board_invite uuid,
  p_bet_amount numeric,
  p_turn_seconds integer,
  p_host_color text,
  p_first_player text
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  inv public.board_invitations%rowtype;
  other uuid;
  created jsonb;
  rid uuid;
  guest_color text;
begin
  select * into inv from public.board_invitations where id=p_board_invite for update;
  if inv.id is null or inv.status<>'accepted' or inv.selected_game<>'dama'
     or (inv.sender_id<>me and inv.target_id<>me) then
    raise exception 'Convite global de Dama inválido.';
  end if;

  other:=case when inv.sender_id=me then inv.target_id else inv.sender_id end;

  if exists(
    select 1
    from public.dama_room_players rp
    join public.dama_rooms r on r.id=rp.room_id
    where rp.player_id=other and rp.status<>'left'
      and r.status in ('waiting','negotiating','funding','ready','playing')
  ) then
    raise exception 'O adversário já está numa partida de Dama.';
  end if;

  created:=public.jl_dama_create_room(
    p_token,p_bet_amount,p_turn_seconds,p_host_color,p_first_player,false
  );
  rid:=(created->'room'->>'id')::uuid;
  guest_color:=case lower(p_host_color) when 'white' then 'red' else 'white' end;

  update public.dama_rooms
  set guest_id=other,status='negotiating',updated_at=now()
  where id=rid;

  insert into public.dama_room_players(
    room_id,player_id,seat,color,settings_accepted
  ) values(rid,other,2,guest_color,false);

  update public.board_invitations
  set status='consumed',consumed_at=now()
  where id=p_board_invite;

  perform public.jl_dama_event(
    rid,me,'board_invite_attached',
    jsonb_build_object('board_invite',p_board_invite,'opponent',other)
  );

  perform public.jl_notification_create(
    other,'dama-invite','Desafio de Dama',
    'Confira valor, tempo, cor e quem começa antes de aceitar.',
    './dama.html?room='||rid::text,
    'dama-board-invite:'||rid::text
  );

  return public.jl_dama_room_state(p_token,rid);
end;
$$;

create or replace function public.jl_ludo_create_from_board_invite(
  p_token text,
  p_board_invite uuid,
  p_bet_amount numeric,
  p_rules jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  inv public.board_invitations%rowtype;
  other uuid;
  created jsonb;
  rid uuid;
begin
  select * into inv from public.board_invitations where id=p_board_invite for update;
  if inv.id is null or inv.status<>'accepted' or inv.selected_game<>'ludo'
     or (inv.sender_id<>me and inv.target_id<>me) then
    raise exception 'Convite global de Ludo inválido.';
  end if;

  other:=case when inv.sender_id=me then inv.target_id else inv.sender_id end;

  created:=public.jl_ludo_create_room(
    p_token,2,p_bet_amount,'solo',false,coalesce(p_rules,'{}'::jsonb)
  );
  rid:=(created->'room'->>'id')::uuid;

  perform public.jl_ludo_invite(p_token,rid,other);

  update public.board_invitations
  set status='consumed',consumed_at=now()
  where id=p_board_invite;

  perform public.jl_ludo_event(
    rid,me,'board_invite_attached',
    jsonb_build_object('board_invite',p_board_invite,'opponent',other)
  );

  return public.jl_ludo_room_state(p_token,rid);
end;
$$;

revoke all on function public.jl_dama_create_from_board_invite(text,uuid,numeric,integer,text,text)
from public,anon,authenticated;
revoke all on function public.jl_ludo_create_from_board_invite(text,uuid,numeric,jsonb)
from public,anon,authenticated;

grant execute on function public.jl_dama_create_from_board_invite(text,uuid,numeric,integer,text,text)
to anon,authenticated;
grant execute on function public.jl_ludo_create_from_board_invite(text,uuid,numeric,jsonb)
to anon,authenticated;

-- Permite retomar uma partida após desconexão mesmo se o prazo visual de reentrada passou.

create or replace function public.jl_ludo_reenter(p_token text, p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  rp public.ludo_room_players%rowtype;
  pl public.players%rowtype;
  amt numeric;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  select * into rp from public.ludo_room_players where room_id=p_room and player_id=me for update;

  if r.status<>'playing' or rp.status<>'reentry' then
    raise exception 'Reentrada indisponível.';
  end if;

  amt:=(r.rules->>'reentry_amount')::numeric;
  select * into pl from public.players where id=me for update;
  if pl.balance<amt then raise exception 'Saldo insuficiente para reentrar.'; end if;

  update public.players set balance=balance-amt,updated_at=now() where id=me;
  update public.ludo_rooms set pot=pot+amt,updated_at=now() where id=p_room;
  update public.ludo_room_players set status='active',reentry_deadline=null where room_id=p_room and player_id=me;

  insert into public.transactions(player_id,kind,amount,status,reference_id,note)
  values(me,'ludo_reentry',-amt,'completed',p_room,'Reentrada no Ludo '||r.code);

  perform public.jl_ludo_event(p_room,me,'player_reentered',jsonb_build_object('amount',amt,'late_reconnect_allowed',true));
  return public.jl_ludo_room_state(p_token,p_room);
end;
$$;

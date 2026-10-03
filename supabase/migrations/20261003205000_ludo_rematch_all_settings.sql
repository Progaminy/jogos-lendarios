-- Revanche Ludo com definições ajustáveis.
create or replace function public.jl_ludo_rematch_v2(
  p_token text,
  p_room uuid,
  p_bet_amount numeric,
  p_mode text,
  p_rules jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  created jsonb;
  new_room uuid;
  existing uuid;
  x record;
  new_rules jsonb;
  new_mode text:=lower(trim(coalesce(p_mode,'')));
begin
  select * into r from public.ludo_rooms where id=p_room for update;

  if r.id is null or r.status<>'finished' then
    raise exception 'A partida anterior ainda não terminou.';
  end if;
  if not exists(
    select 1 from public.ludo_room_players
    where room_id=p_room and player_id=me and status<>'left'
  ) then
    raise exception 'Você não participou desta partida.';
  end if;
  if p_bet_amount is null or p_bet_amount<10 or p_bet_amount<>trunc(p_bet_amount) then
    raise exception 'A nova aposta deve ser um valor inteiro de pelo menos 10 MZN.';
  end if;
  if new_mode not in ('solo','partners') then raise exception 'Modo inválido.'; end if;
  if new_mode='partners' and r.player_count<>4 then
    raise exception 'Parceiros exige 4 jogadores.';
  end if;

  select (e.payload->>'new_room')::uuid
  into existing
  from public.ludo_events e
  join public.ludo_rooms nr on nr.id=(e.payload->>'new_room')::uuid
  where e.room_id=p_room
    and e.event_type='rematch_created'
    and nr.status in ('waiting','negotiating','funding','playing')
  order by e.id desc
  limit 1;

  if existing is not null then
    if public.jl_ludo_is_member(existing,me) then
      return public.jl_ludo_room_state(p_token,existing);
    end if;
    raise exception 'Já existe uma repetição desta partida.';
  end if;

  new_rules:=r.rules || coalesce(p_rules,'{}'::jsonb);
  new_rules:=jsonb_set(new_rules,'{voice_enabled}','true'::jsonb,true);

  created:=public.jl_ludo_create_room(
    p_token,
    r.player_count,
    p_bet_amount,
    new_mode,
    false,
    new_rules
  );
  new_room:=(created->'room'->>'id')::uuid;

  for x in
    select player_id
    from public.ludo_room_players
    where room_id=p_room and status<>'left' and player_id<>me
    order by seat
  loop
    perform public.jl_ludo_invite(p_token,new_room,x.player_id);
  end loop;

  perform public.jl_ludo_event(
    p_room,me,'rematch_created',
    jsonb_build_object(
      'new_room',new_room,
      'bet_amount',p_bet_amount,
      'player_count',r.player_count,
      'mode',new_mode,
      'rules',new_rules
    )
  );

  return public.jl_ludo_room_state(p_token,new_room);
end;
$$;

revoke all on function public.jl_ludo_rematch_v2(text,uuid,numeric,text,jsonb)
from public,anon,authenticated;
grant execute on function public.jl_ludo_rematch_v2(text,uuid,numeric,text,jsonb)
to anon,authenticated;

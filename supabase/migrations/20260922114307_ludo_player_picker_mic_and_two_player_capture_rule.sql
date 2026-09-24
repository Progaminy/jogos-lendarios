-- Melhoria 5: em partidas de 2 jogadores, ignorar captura nunca elimina.
-- A única penalização permitida nesse caso é perder a vez.

create or replace function public.jl_ludo_apply_capture_penalty(p_room uuid, p_player uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ludo_rooms%rowtype;
  pen text;
  secs int;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  pen:=r.rules->>'capture_penalty';

  if r.player_count=2 then
    pen:='lose_turn';
  end if;

  if pen='lose_turn' then
    perform public.jl_ludo_event(
      p_room,p_player,'capture_required_missed',
      jsonb_build_object('penalty','lose_turn')
    );
    perform public.jl_ludo_advance_turn(p_room,p_player,false);
  elsif pen='eliminate' or not (r.rules->>'reentry_allowed')::boolean then
    update public.ludo_room_players
    set status='eliminated',reentry_deadline=null
    where room_id=p_room and player_id=p_player;
    perform public.jl_ludo_event(
      p_room,p_player,'player_eliminated',
      jsonb_build_object('reason','capture_required')
    );
    perform public.jl_ludo_advance_turn(p_room,p_player,false);
  else
    secs:=(r.rules->>'reentry_seconds')::int;
    update public.ludo_room_players
    set status='reentry',
        reentry_deadline=now()+make_interval(secs=>secs)
    where room_id=p_room and player_id=p_player;
    perform public.jl_ludo_event(
      p_room,p_player,'reentry_required',
      jsonb_build_object(
        'reason','capture_required',
        'amount',(r.rules->>'reentry_amount')::numeric,
        'deadline',now()+make_interval(secs=>secs)
      )
    );
    perform public.jl_ludo_advance_turn(p_room,p_player,false);
  end if;

  return pen;
end;
$$;

create or replace function public.jl_ludo_create_room(
  p_token text,
  p_player_count integer,
  p_bet_amount numeric,
  p_mode text default 'solo'::text,
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
  if p_bet_amount <> trunc(p_bet_amount) then raise exception 'A aposta deve ser um valor inteiro em MZN.'; end if;

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

  if p_player_count=2 then
    v_rules:=jsonb_set(v_rules,'{capture_penalty}','"lose_turn"'::jsonb,true);
  end if;

  insert into public.ludo_rooms(
    code,host_id,player_count,mode,bet_amount,is_public,rules,status,action_deadline
  ) values(
    public.jl_ludo_room_code(),v_player,p_player_count,p_mode,round(p_bet_amount,2),p_is_public,v_rules,'waiting',null
  ) returning * into v_room;

  insert into public.ludo_room_players(
    room_id,player_id,seat,color,team,accepted_rules_version
  ) values(
    v_room.id,v_player,1,'red',case when p_mode='partners' then 1 else null end,v_room.rules_version
  );

  perform public.jl_ludo_event(
    v_room.id,v_player,'room_created',
    jsonb_build_object('code',v_room.code,'bet',v_room.bet_amount,'players',v_room.player_count,'mode',v_room.mode)
  );

  return public.jl_ludo_room_state(p_token,v_room.id);
end;
$$;

create or replace function public.jl_ludo_update_rules(p_token text, p_room uuid, p_rules jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  nr jsonb;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.id is null or r.host_id<>me then raise exception 'Apenas o anfitrião pode alterar as regras.'; end if;
  if r.status not in ('waiting','negotiating') then raise exception 'As regras já estão bloqueadas para esta partida.'; end if;

  nr := public.jl_ludo_rules(p_rules,r.bet_amount);

  if r.player_count=2 then
    nr:=jsonb_set(nr,'{capture_penalty}','"lose_turn"'::jsonb,true);
  end if;

  update public.ludo_rooms
  set rules=nr,
      rules_version=rules_version+1,
      status='negotiating',
      action_deadline=now()+make_interval(secs=>(nr->>'rules_response_seconds')::int),
      negotiation_grace_used=false,
      updated_at=now()
  where id=p_room returning * into r;

  update public.ludo_room_players
  set accepted_rules_version=null
  where room_id=p_room and status<>'left';

  update public.ludo_room_players
  set accepted_rules_version=r.rules_version
  where room_id=p_room and player_id=me;

  perform public.jl_ludo_event(
    p_room,me,'rules_changed',
    jsonb_build_object('version',r.rules_version,'rules',nr)
  );

  return public.jl_ludo_room_state(p_token,p_room);
end;
$$;

update public.ludo_rooms
set rules=jsonb_set(rules,'{capture_penalty}','"lose_turn"'::jsonb,true),
    updated_at=now()
where player_count=2
  and status in ('waiting','negotiating','funding','playing')
  and coalesce(rules->>'capture_penalty','')<>'lose_turn';

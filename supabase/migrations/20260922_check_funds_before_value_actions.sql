-- Melhoria 16: verificar fundos antes de qualquer movimento de valor e direcionar para depósito quando faltar saldo.

CREATE OR REPLACE FUNCTION public.jl_check_funds(p_token text, p_game_type text, p_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid:=public.jl_player_id(p_token);
  cash numeric:=0;
  bonus numeric:=0;
  locked numeric:=0;
  available numeric:=0;
  reason text:='ok';
  redirect boolean:=false;
begin
  if p_amount is null or p_amount<0 then
    raise exception 'Valor inválido.';
  end if;

  if p_game_type not in ('number','pair','ludo','withdrawal') then
    raise exception 'Tipo de movimento financeiro inválido.';
  end if;

  select balance into cash
  from public.players
  where id=me;

  if p_game_type in ('number','pair') then
    bonus:=public.jl_bonus_available(me,p_game_type);
    available:=cash+bonus;
    if available<p_amount then
      reason:='insufficient_balance';
      redirect:=true;
    end if;

  elsif p_game_type='ludo' then
    available:=cash;
    if available<p_amount then
      reason:='insufficient_balance';
      redirect:=true;
    end if;

  else
    locked:=public.jl_deposit_wager_locked(me);
    available:=greatest(0,cash-locked);

    if available<p_amount then
      if cash<p_amount then
        reason:='insufficient_balance';
        redirect:=true;
      else
        reason:='deposit_not_played';
        redirect:=false;
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'ok',available>=p_amount,
    'game_type',p_game_type,
    'required',round(p_amount,2),
    'cash_balance',round(cash,2),
    'bonus_available',round(bonus,2),
    'deposit_locked',round(locked,2),
    'available',round(available,2),
    'shortfall',round(greatest(0,p_amount-available),2),
    'reason',reason,
    'redirect_to_deposit',redirect
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.jl_ludo_accept_invite(p_token text, p_invitation uuid, p_accept boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid:=public.jl_player_id(p_token);
  i public.ludo_invitations%rowtype;
  target_room public.ludo_rooms%rowtype;
  current_room public.ludo_rooms%rowtype;
  current_id uuid;
  replacement_host uuid;
  others_count int;
begin
  select * into i
  from public.ludo_invitations
  where id=p_invitation and target_player_id=me
  for update;

  if i.id is null then raise exception 'Convite não encontrado.'; end if;

  select * into target_room
  from public.ludo_rooms
  where id=i.room_id
  for update;

  if not p_accept then
    if i.status='pending' then
      update public.ludo_invitations set status='declined' where id=i.id;
    end if;
    return jsonb_build_object('ok',true,'accepted',false,'status','declined');
  end if;

  if i.status not in ('pending','accepted') then
    raise exception 'Este convite já não está disponível.';
  end if;

  if target_room.id is null or target_room.status not in ('waiting','negotiating') then
    raise exception 'A sala deste convite já não está disponível.';
  end if;

  if exists(
    select 1 from public.ludo_room_players
    where room_id=i.room_id and player_id=me and status<>'left'
  ) then
    if i.status='pending' then update public.ludo_invitations set status='accepted' where id=i.id; end if;
    return public.jl_ludo_room_state(p_token,i.room_id);
  end if;

  perform public.jl_require_cash_balance(me,target_room.bet_amount);

  select r.id into current_id
  from public.ludo_room_players rp
  join public.ludo_rooms r on r.id=rp.room_id
  where rp.player_id=me
    and rp.status<>'left'
    and r.status in ('waiting','negotiating','funding','playing')
    and r.id<>i.room_id
  order by r.created_at desc
  limit 1;

  if current_id is not null then
    select * into current_room
    from public.ludo_rooms
    where id=current_id
    for update;

    if current_room.host_id<>me
       or current_room.status not in ('waiting','negotiating') then
      raise exception 'Termine ou saia da sala atual antes de aceitar este convite.';
    end if;

    select count(*) into others_count
    from public.ludo_room_players
    where room_id=current_id
      and status<>'left'
      and player_id<>me;

    if others_count=0 then
      update public.ludo_invitations
      set status='cancelled'
      where room_id=current_id and status='pending';

      update public.ludo_room_players
      set status='left'
      where room_id=current_id and player_id=me;

      update public.ludo_rooms
      set status='cancelled',
          action_deadline=null,
          updated_at=now()
      where id=current_id;

      perform public.jl_ludo_event(
        current_id,me,'host_switched_to_invited_room',
        jsonb_build_object('cancelled_empty_room',true,'target_room',i.room_id)
      );
    else
      select player_id into replacement_host
      from public.ludo_room_players
      where room_id=current_id
        and status<>'left'
        and player_id<>me
      order by seat limit 1;

      update public.ludo_room_players
      set status='left'
      where room_id=current_id and player_id=me;

      update public.ludo_rooms
      set host_id=replacement_host,
          status='waiting',
          action_deadline=null,
          negotiation_grace_used=false,
          updated_at=now()
      where id=current_id;

      perform public.jl_ludo_event(
        current_id,me,'host_transferred_for_invite',
        jsonb_build_object('new_host',replacement_host,'target_room',i.room_id)
      );
    end if;
  end if;

  perform public.jl_ludo_join_room_internal(i.room_id,me);

  if not exists(
    select 1 from public.ludo_room_players
    where room_id=i.room_id and player_id=me and status<>'left'
  ) then
    raise exception 'Não foi possível concluir a entrada na sala convidada.';
  end if;

  update public.ludo_invitations
  set status='accepted'
  where id=i.id;

  delete from public.ludo_waiting_queue where player_id=me;

  return public.jl_ludo_room_state(p_token,i.room_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.jl_ludo_accept_public_challenge(p_token text, p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid:=public.jl_player_id(p_token);
  target public.ludo_rooms%rowtype;
  current_room public.ludo_rooms%rowtype;
  current_id uuid;
  joined int;
begin
  select * into target
  from public.ludo_rooms
  where upper(code)=upper(trim(p_code))
    and is_public
    and status in ('waiting','negotiating')
  for update;

  if target.id is null then raise exception 'Desafio público não encontrado.'; end if;

  select count(*) into joined
  from public.ludo_room_players
  where room_id=target.id and status<>'left';

  if joined>=target.player_count then raise exception 'Este desafio já está completo.'; end if;

  select r.id into current_id
  from public.ludo_room_players rp
  join public.ludo_rooms r on r.id=rp.room_id
  where rp.player_id=me
    and rp.status<>'left'
    and r.status in ('waiting','negotiating','funding','playing')
  order by r.created_at desc
  limit 1;

  if current_id=target.id then
    return public.jl_ludo_room_state(p_token,target.id);
  end if;

  perform public.jl_require_cash_balance(me,target.bet_amount);

  if current_id is not null then
    select * into current_room
    from public.ludo_rooms
    where id=current_id
    for update;

    if current_room.status not in ('waiting','negotiating') then
      raise exception 'Você já está numa partida que não pode ser trocada agora.';
    end if;

    select count(*) into joined
    from public.ludo_room_players
    where room_id=current_id and status<>'left';

    if current_room.host_id=me then
      if joined>1 then
        raise exception 'Sua sala atual já tem outros jogadores. Saia dela antes de aceitar outro desafio.';
      end if;

      update public.ludo_invitations
      set status='cancelled'
      where room_id=current_id and status='pending';

      update public.ludo_room_players
      set status='left'
      where room_id=current_id and player_id=me;

      update public.ludo_rooms
      set status='cancelled',
          action_deadline=null,
          updated_at=now()
      where id=current_id;
    else
      update public.ludo_room_players
      set status='left'
      where room_id=current_id and player_id=me;
    end if;
  end if;

  perform public.jl_ludo_join_room_internal(target.id,me);
  delete from public.ludo_waiting_queue where player_id=me;

  perform public.jl_ludo_event(
    target.id,me,'public_challenge_accepted',
    jsonb_build_object('code',target.code)
  );

  return public.jl_ludo_room_state(p_token,target.id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.jl_ludo_create_room(p_token text, p_player_count integer, p_bet_amount numeric, p_mode text DEFAULT 'solo'::text, p_is_public boolean DEFAULT false, p_rules jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_player uuid:=public.jl_player_id(p_token);
  v_room public.ludo_rooms%rowtype;
  v_rules jsonb;
begin
  if p_player_count not between 2 and 4 then raise exception 'Ludo aceita 2, 3 ou 4 jogadores.'; end if;
  if p_mode not in ('solo','partners') then raise exception 'Modo inválido.'; end if;
  if p_mode='partners' and p_player_count<>4 then raise exception 'Modo parceiros requer 4 jogadores.'; end if;
  if p_bet_amount is null or p_bet_amount<10 then raise exception 'A aposta mínima é 10 MZN.'; end if;
  if p_bet_amount<>trunc(p_bet_amount) then raise exception 'A aposta deve ser um valor inteiro em MZN.'; end if;

  perform public.jl_require_cash_balance(v_player,p_bet_amount);

  if exists(
    select 1
    from public.ludo_room_players rp
    join public.ludo_rooms r on r.id=rp.room_id
    where rp.player_id=v_player
      and rp.status<>'left'
      and r.status in ('waiting','negotiating','funding','playing')
  ) then
    raise exception 'Você já participa de uma sala de Ludo ativa.';
  end if;

  perform public.jl_ludo_ensure_code(v_player);
  v_rules:=public.jl_ludo_rules(p_rules,p_bet_amount);

  if p_player_count=2 then
    v_rules:=jsonb_set(v_rules,'{capture_penalty}','"lose_turn"'::jsonb,true);
  end if;

  insert into public.ludo_rooms(
    code,host_id,player_count,mode,bet_amount,is_public,rules,status,action_deadline
  ) values(
    public.jl_ludo_room_code(),v_player,p_player_count,p_mode,
    round(p_bet_amount,2),p_is_public,v_rules,'waiting',null
  ) returning * into v_room;

  insert into public.ludo_room_players(
    room_id,player_id,seat,color,team,accepted_rules_version
  ) values(
    v_room.id,v_player,1,'red',
    case when p_mode='partners' then 1 else null end,
    v_room.rules_version
  );

  perform public.jl_ludo_event(
    v_room.id,v_player,'room_created',
    jsonb_build_object(
      'code',v_room.code,
      'bet',v_room.bet_amount,
      'players',v_room.player_count,
      'mode',v_room.mode
    )
  );

  return public.jl_ludo_room_state(p_token,v_room.id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.jl_ludo_enter_queue(p_token text, p_bet_amount numeric, p_player_count integer, p_mode text DEFAULT 'solo'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid:=public.jl_player_id(p_token);
begin
  if p_player_count not between 2 and 4 then raise exception 'Quantidade de jogadores inválida.'; end if;
  if p_mode not in ('solo','partners') or (p_mode='partners' and p_player_count<>4) then raise exception 'Modo inválido.'; end if;
  if p_bet_amount is null or p_bet_amount<10 then raise exception 'A aposta mínima é 10 MZN.'; end if;
  if p_bet_amount<>trunc(p_bet_amount) then raise exception 'A aposta deve ser um valor inteiro em MZN.'; end if;

  perform public.jl_require_cash_balance(me,p_bet_amount);

  if exists(
    select 1
    from public.ludo_room_players rp
    join public.ludo_rooms r on r.id=rp.room_id
    where rp.player_id=me
      and rp.status<>'left'
      and r.status in ('waiting','negotiating','funding','playing')
  ) then raise exception 'Você já participa de uma sala ativa.'; end if;

  perform public.jl_ludo_ensure_code(me);

  insert into public.ludo_waiting_queue(
    player_id,bet_amount,player_count,mode,joined_at,expires_at
  ) values(
    me,round(p_bet_amount,2),p_player_count,p_mode,now(),now()+interval '15 minutes'
  )
  on conflict(player_id) do update
  set bet_amount=excluded.bet_amount,
      player_count=excluded.player_count,
      mode=excluded.mode,
      joined_at=now(),
      expires_at=excluded.expires_at;

  return jsonb_build_object(
    'ok',true,
    'code',public.jl_ludo_display_code(me),
    'expires_at',now()+interval '15 minutes'
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.jl_ludo_join_room_internal(p_room uuid, p_player uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r public.ludo_rooms%rowtype;
  s int;
  col text;
  tm int;
  joined_now int;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.id is null or r.status not in ('waiting','negotiating') then raise exception 'Sala indisponível.'; end if;

  if exists(
    select 1 from public.ludo_room_players
    where room_id=p_room and player_id=p_player and status<>'left'
  ) then return; end if;

  perform public.jl_require_cash_balance(p_player,r.bet_amount);

  if exists(
    select 1
    from public.ludo_room_players rp
    join public.ludo_rooms rr on rr.id=rp.room_id
    where rp.player_id=p_player and rp.status<>'left'
      and rr.status in ('waiting','negotiating','funding','playing')
      and rr.id<>p_room
  ) then raise exception 'O jogador já participa de outra sala ativa.'; end if;

  if (
    select count(*) from public.ludo_room_players
    where room_id=p_room and status<>'left'
  )>=r.player_count then raise exception 'Sala cheia.'; end if;

  select x into s
  from generate_series(1,r.player_count) x
  where not exists(
    select 1 from public.ludo_room_players
    where room_id=p_room and seat=x and status<>'left'
  )
  order by x limit 1;

  col:=case s
    when 1 then 'red'
    when 2 then case when r.player_count=2 then 'yellow' else 'green' end
    when 3 then 'yellow'
    else 'blue'
  end;
  if r.player_count=2 and s=2 then col:='yellow'; end if;

  tm:=case when r.mode='partners'
    then case when s in (1,3) then 1 else 2 end
    else null
  end;

  insert into public.ludo_room_players(
    room_id,player_id,seat,color,team,status
  ) values(
    p_room,p_player,s,col,tm,'active'
  );

  perform public.jl_ludo_ensure_code(p_player);

  update public.ludo_rooms
  set status='negotiating',
      action_deadline=null,
      negotiation_grace_used=false,
      updated_at=now()
  where id=p_room;

  perform public.jl_ludo_event(
    p_room,p_player,'player_joined',
    jsonb_build_object('seat',s,'color',col,'team',tm)
  );

  select count(*) into joined_now
  from public.ludo_room_players
  where room_id=p_room and status<>'left';

  if joined_now>=r.player_count then
    update public.ludo_invitations i
    set status='cancelled'
    where i.room_id=p_room
      and i.status in ('pending','accepted')
      and i.target_player_id<>p_player
      and not exists(
        select 1 from public.ludo_room_players rp
        where rp.room_id=p_room
          and rp.player_id=i.target_player_id
          and rp.status<>'left'
      );
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.jl_require_cash_balance(p_player_id uuid, p_amount numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  cash numeric:=0;
  missing numeric:=0;
begin
  if p_amount is null or p_amount<0 then
    raise exception 'Valor inválido.';
  end if;

  select balance into cash
  from public.players
  where id=p_player_id
  for update;

  if cash<p_amount then
    missing:=p_amount-cash;
    raise exception 'Saldo insuficiente. Faltam % MZN. Faça um depósito.',round(missing,2);
  end if;
end;
$function$;

revoke all on function public.jl_require_cash_balance(uuid,numeric) from public,anon,authenticated;

revoke all on function public.jl_check_funds(text,text,numeric) from public;
grant execute on function public.jl_check_funds(text,text,numeric) to anon,authenticated;

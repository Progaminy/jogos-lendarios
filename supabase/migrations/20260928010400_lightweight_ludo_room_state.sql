-- Ponto 11 — tornar o estado da sala do Ludo mais leve.
-- Mantém regras, movimentos, timers e contratos antigos.
-- Polling passa a usar estado essencial + deltas incrementais de eventos/chat.
-- display_code deixa de escrever no banco em operações de leitura.

insert into public.ludo_player_codes(player_id)
select p.id
from public.players p
where p.deleted_at is null
on conflict(player_id) do nothing;

create or replace function public.jl_ludo_display_code(p_player_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  n bigint;
  nm text;
  prefix text;
begin
  select p.name,c.house_number
  into nm,n
  from public.players p
  left join public.ludo_player_codes c on c.player_id=p.id
  where p.id=p_player_id;

  prefix:=coalesce(nullif(split_part(trim(coalesce(nm,'')),' ',1),''),'Jogador');

  if n is null then
    return prefix;
  end if;

  return prefix || lpad(n::text,3,'0');
end;
$function$;

create or replace function public.jl_ludo_room_state_light(
  p_token text,
  p_room uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  mymoves jsonb:='[]'::jsonb;
  ident jsonb;
begin
  select * into r
  from public.ludo_rooms
  where id=p_room;

  if r.id is null or not public.jl_ludo_is_member(p_room,me) then
    raise exception 'Sala de Ludo não encontrada.';
  end if;

  if r.status='playing'
     and r.current_player_id=me
     and r.turn_phase='move'
     and r.dice_result is not null then
    mymoves:=public.jl_ludo_legal_moves_data(p_room,me,r.dice_result);
  end if;

  ident:=jsonb_build_object(
    'player_id',me,
    'code',public.jl_ludo_display_code(me),
    'house_number',(select house_number from public.ludo_player_codes where player_id=me)
  );

  return jsonb_build_object(
    'identity',ident,
    'room',to_jsonb(r),
    'players',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'player_id',rp.player_id,
          'name',p.name,
          'code',coalesce(nullif(split_part(trim(p.name),' ',1),''),'Jogador') || lpad(c.house_number::text,3,'0'),
          'house_number',c.house_number,
          'seat',rp.seat,
          'color',rp.color,
          'team',rp.team,
          'accepted_rules_version',rp.accepted_rules_version,
          'stake_paid',rp.stake_paid,
          'stake_amount',rp.stake_amount,
          'status',rp.status,
          'timeout_strikes',rp.timeout_strikes,
          'reentry_deadline',rp.reentry_deadline
        )
        order by rp.seat
      )
      from public.ludo_room_players rp
      join public.players p on p.id=rp.player_id
      join public.ludo_player_codes c on c.player_id=rp.player_id
      where rp.room_id=p_room
        and rp.status<>'left'
    ),'[]'::jsonb),
    'tokens',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'player_id',t.player_id,
          'token_no',t.token_no,
          'steps',t.steps
        )
        order by rp.seat,t.token_no
      )
      from public.ludo_tokens t
      join public.ludo_room_players rp
        on rp.room_id=t.room_id
       and rp.player_id=t.player_id
      where t.room_id=p_room
    ),'[]'::jsonb),
    'legal_moves',mymoves
  );
end;
$function$;

revoke all on function public.jl_ludo_room_state_light(text,uuid)
from public,anon,authenticated;
grant execute on function public.jl_ludo_room_state_light(text,uuid)
to anon,authenticated,service_role;

create or replace function public.jl_ludo_room_delta(
  p_token text,
  p_room uuid,
  p_after_event bigint default 0,
  p_after_chat bigint default 0,
  p_include_payouts boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  me uuid:=public.jl_player_id(p_token);
  v_events jsonb;
  v_chat jsonb;
  v_payouts jsonb:='[]'::jsonb;
begin
  if not public.jl_ludo_is_member(p_room,me) then
    raise exception 'Sala de Ludo não encontrada.';
  end if;

  if coalesce(p_after_event,0)<=0 then
    select coalesce(jsonb_agg(x.obj order by x.id),'[]'::jsonb)
    into v_events
    from (
      select e.id,
             jsonb_build_object(
               'id',e.id,
               'player_id',e.player_id,
               'event_type',e.event_type,
               'payload',e.payload,
               'created_at',e.created_at
             ) obj
      from public.ludo_events e
      where e.room_id=p_room
      order by e.id desc
      limit 50
    ) x;
  else
    select coalesce(jsonb_agg(x.obj order by x.id),'[]'::jsonb)
    into v_events
    from (
      select e.id,
             jsonb_build_object(
               'id',e.id,
               'player_id',e.player_id,
               'event_type',e.event_type,
               'payload',e.payload,
               'created_at',e.created_at
             ) obj
      from public.ludo_events e
      where e.room_id=p_room
        and e.id>p_after_event
      order by e.id
      limit 100
    ) x;
  end if;

  if coalesce(p_after_chat,0)<=0 then
    select coalesce(jsonb_agg(x.obj order by x.id),'[]'::jsonb)
    into v_chat
    from (
      select ch.id,
             jsonb_build_object(
               'id',ch.id,
               'player_id',ch.player_id,
               'name',p.name,
               'code',coalesce(nullif(split_part(trim(p.name),' ',1),''),'Jogador') || lpad(c.house_number::text,3,'0'),
               'message',ch.message,
               'created_at',ch.created_at
             ) obj
      from public.ludo_chat ch
      join public.players p on p.id=ch.player_id
      join public.ludo_player_codes c on c.player_id=ch.player_id
      where ch.room_id=p_room
      order by ch.id desc
      limit 50
    ) x;
  else
    select coalesce(jsonb_agg(x.obj order by x.id),'[]'::jsonb)
    into v_chat
    from (
      select ch.id,
             jsonb_build_object(
               'id',ch.id,
               'player_id',ch.player_id,
               'name',p.name,
               'code',coalesce(nullif(split_part(trim(p.name),' ',1),''),'Jogador') || lpad(c.house_number::text,3,'0'),
               'message',ch.message,
               'created_at',ch.created_at
             ) obj
      from public.ludo_chat ch
      join public.players p on p.id=ch.player_id
      join public.ludo_player_codes c on c.player_id=ch.player_id
      where ch.room_id=p_room
        and ch.id>p_after_chat
      order by ch.id
      limit 100
    ) x;
  end if;

  if coalesce(p_include_payouts,false) then
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'player_id',lp.player_id,
        'gross',lp.gross_amount,
        'commission',lp.commission,
        'net',lp.net_amount
      )
    ),'[]'::jsonb)
    into v_payouts
    from public.ludo_payouts lp
    where lp.room_id=p_room;
  end if;

  return jsonb_build_object(
    'events',coalesce(v_events,'[]'::jsonb),
    'chat',coalesce(v_chat,'[]'::jsonb),
    'payouts',coalesce(v_payouts,'[]'::jsonb)
  );
end;
$function$;

revoke all on function public.jl_ludo_room_delta(text,uuid,bigint,bigint,boolean)
from public,anon,authenticated;
grant execute on function public.jl_ludo_room_delta(text,uuid,bigint,bigint,boolean)
to anon,authenticated,service_role;

create or replace function public.jl_ludo_room_state(p_token text,p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_light jsonb;
  v_delta jsonb;
begin
  v_light:=public.jl_ludo_room_state_light(p_token,p_room);
  v_delta:=public.jl_ludo_room_delta(p_token,p_room,0,0,true);

  return v_light || jsonb_build_object(
    'events',v_delta->'events',
    'chat',v_delta->'chat',
    'payouts',v_delta->'payouts'
  );
end;
$function$;

create or replace function public.jl_ludo_my_status(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  me uuid:=public.jl_player_id(p_token);
  rid uuid;
  online_total int;
begin
  update public.player_sessions
  set last_seen_at=now()
  where token_hash=public.jl_token_hash(p_token)
    and expires_at>now();

  delete from public.ludo_waiting_queue
  where expires_at<=now();

  select count(distinct player_id)
  into online_total
  from public.player_sessions
  where expires_at>now()
    and last_seen_at>=now()-interval '20 seconds';

  select r.id into rid
  from public.ludo_room_players rp
  join public.ludo_rooms r on r.id=rp.room_id
  where rp.player_id=me
    and rp.status<>'left'
    and r.status in ('waiting','negotiating','funding','playing')
  order by r.created_at desc
  limit 1;

  return jsonb_build_object(
    'identity',jsonb_build_object(
      'player_id',me,
      'name',(select name from public.players where id=me),
      'code',public.jl_ludo_display_code(me),
      'house_number',(select house_number from public.ludo_player_codes where player_id=me),
      'balance',(select balance from public.players where id=me)
    ),
    'active_room_id',rid,
    'online_count',online_total,
    'queue',(select case when w.player_id is null then null else to_jsonb(w) end
             from public.ludo_waiting_queue w where w.player_id=me),
    'invites',public.jl_ludo_my_invites(p_token)
  );
end;
$function$;

create or replace function public.jl_register_player(
  p_name text,
  p_phone text,
  p_pin text,
  p_invite_code text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_phone text := public.jl_phone(p_phone);
  v_player public.players%rowtype;
  v_token text;
  v_invite_code text := upper(trim(coalesce(p_invite_code,'')));
  v_influencer public.influencers%rowtype;
begin
  p_name := trim(coalesce(p_name,''));
  if char_length(p_name) < 2 or char_length(p_name) > 60 then
    raise exception 'Informe um nome entre 2 e 60 caracteres.';
  end if;
  if char_length(v_phone) < 8 or char_length(v_phone) > 15 then
    raise exception 'Número de telefone inválido.';
  end if;
  if coalesce(p_pin,'') !~ '^[0-9]{4,8}$' then
    raise exception 'O PIN deve ter de 4 a 8 dígitos.';
  end if;

  if v_invite_code <> '' then
    select * into v_influencer
    from public.influencers i
    where i.code=v_invite_code
      and i.active
    limit 1;

    if v_influencer.id is null then
      raise exception 'Código de convite inválido ou inativo.';
    end if;
  end if;

  if exists(
    select 1
    from public.players
    where deleted_at is null
      and public.jl_phone(phone)=v_phone
  ) then
    raise exception 'Este número já possui uma conta. Entre nessa conta ou recupere o PIN.';
  end if;

  begin
    insert into public.players(name,phone,pin_hash)
    values(
      p_name,
      v_phone,
      extensions.crypt(p_pin,extensions.gen_salt('bf',10))
    )
    returning * into v_player;
  exception
    when unique_violation then
      raise exception 'Este número já possui uma conta. Entre nessa conta ou recupere o PIN.';
  end;

  perform public.jl_ludo_ensure_code(v_player.id);

  if v_influencer.id is not null then
    insert into public.influencer_referrals(player_id,influencer_id,code_used)
    values(v_player.id,v_influencer.id,v_invite_code);
  end if;

  v_token:=encode(extensions.gen_random_bytes(32),'hex');
  insert into public.player_sessions(player_id,token_hash,expires_at)
  values(v_player.id,public.jl_token_hash(v_token),now()+interval '30 days');

  return jsonb_build_object(
    'token',v_token,
    'player',jsonb_build_object(
      'id',v_player.id,
      'name',v_player.name,
      'phone',v_player.phone,
      'balance',v_player.balance,
      'blocked',v_player.blocked
    ),
    'referral',case
      when v_influencer.id is null then null
      else jsonb_build_object(
        'influencer_id',v_influencer.id,
        'influencer',v_influencer.name,
        'code',v_invite_code
      )
    end
  );
end;
$function$;

create or replace function public.jl_ludo_process_timeouts(p_token text,p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  cur uuid;
begin
  if not public.jl_ludo_is_member(p_room,me) then
    raise exception 'Você não pertence a esta sala.';
  end if;

  select * into r
  from public.ludo_rooms
  where id=p_room
  for update;

  if r.status='funding'
     and r.action_deadline is not null
     and r.action_deadline<=now() then

    delete from public.ludo_room_players
    where room_id=p_room
      and player_id<>r.host_id
      and not stake_paid;

    perform public.jl_ludo_refund_room(
      p_room,'Reembolso: tempo de confirmação da sala expirou'
    );

    update public.ludo_room_players
    set accepted_rules_version=case
      when player_id=r.host_id then r.rules_version
      else null
    end
    where room_id=p_room;

    update public.ludo_rooms
    set status='waiting',
        action_deadline=null,
        negotiation_grace_used=false,
        updated_at=now()
    where id=p_room;

    perform public.jl_ludo_event(
      p_room,null,'funding_timeout','{}'::jsonb
    );

  elsif r.status='playing' then
    if public.jl_ludo_check_finish(p_room) then
      return public.jl_ludo_room_state_light(p_token,p_room);
    end if;

    if r.action_deadline is not null
       and r.action_deadline<=now()
       and r.current_player_id is not null then
      cur:=r.current_player_id;

      update public.ludo_room_players
      set timeout_strikes=timeout_strikes+1
      where room_id=p_room
        and player_id=cur;

      perform public.jl_ludo_event(
        p_room,cur,'action_timeout',
        jsonb_build_object(
          'phase',r.turn_phase,
          'action','turn_passed',
          'player_remains_in_game',true
        )
      );

      perform public.jl_ludo_advance_turn(p_room,cur,false);
    end if;
  end if;

  return public.jl_ludo_room_state_light(p_token,p_room);
end;
$function$;

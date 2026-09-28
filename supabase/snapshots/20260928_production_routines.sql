-- Production routines snapshot generated at 2026-09-28 01:48:31.537913+00

CREATE OR REPLACE FUNCTION public.jl_admin_account_id(p_token text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_admin uuid;
  v_session uuid;
  v_name text;
  v_role text;
begin
  delete from public.admin_sessions where expires_at<=now();

  select s.id,s.admin_id,a.display_name,a.role
  into v_session,v_admin,v_name,v_role
  from public.admin_sessions s
  join public.admin_accounts a on a.id=s.admin_id and a.active
  where s.token_hash=public.jl_token_hash(p_token)
    and s.expires_at>now()
  limit 1;

  if v_admin is not null then
    perform set_config('jl.admin_id',v_admin::text,true);
    perform set_config('jl.admin_session_id',v_session::text,true);
    perform set_config('jl.admin_name',coalesce(v_name,''),true);
    perform set_config('jl.admin_role',coalesce(v_role,''),true);
  end if;

  return v_admin;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_add_draw_time(p_token text, p_draw_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return public.jl_admin_add_game_draw_time(p_token,'number',p_draw_at);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_add_game_draw_time(p_token text, p_game_type text, p_draw_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid;
begin
  perform public.jl_require_admin(p_token);
  if p_game_type not in ('number','pair') then raise exception 'Jogo inválido.'; end if;
  if p_draw_at is null or p_draw_at <= now()+interval '10 seconds' or p_draw_at > now()+interval '7 days' then
    raise exception 'Defina um sorteio entre 10 segundos e 7 dias a partir de agora.';
  end if;

  insert into public.draw_schedule(game_type,draw_at)
  values(p_game_type,p_draw_at)
  on conflict (game_type,draw_at) do nothing
  returning id into v_id;

  if v_id is null then raise exception 'Esse horário já está programado para este jogo.'; end if;
  perform public.jl_process_game(p_game_type);
  return jsonb_build_object('ok',true,'id',v_id,'game_type',p_game_type,'draw_at',p_draw_at,'message','Horário adicionado.');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_adjust_balance_idempotent(p_token text, p_player_id uuid, p_delta numeric, p_note text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_admin uuid:=public.jl_admin_account_id(p_token);
  v_hash text; v_claim jsonb; v_response jsonb;
begin
  if v_admin is null then raise exception 'Sessão administrativa inválida ou expirada.'; end if;

  v_hash:=encode(extensions.digest(jsonb_build_object(
    'player_id',p_player_id,
    'delta',round(coalesce(p_delta,0),2),
    'note',left(trim(coalesce(p_note,'')),160)
  )::text,'sha256'),'hex');

  v_claim:=public.jl_financial_idempotency_claim(
    'admin',v_admin,'balance_adjustment',p_idempotency_key,v_hash
  );
  if not (v_claim->>'claimed')::boolean then return v_claim->'response'; end if;

  v_response:=public.jl_admin_adjust_balance(p_token,p_player_id,p_delta,p_note);
  perform public.jl_financial_idempotency_complete(
    'admin',v_admin,'balance_adjustment',p_idempotency_key,v_response
  );
  return v_response;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_adjust_balance(p_token text, p_player_id uuid, p_delta numeric, p_note text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_balance numeric;
begin
  perform public.jl_require_admin_elevated(p_token);
  if p_delta is null or p_delta=0 or abs(p_delta)>1000000 then raise exception 'Ajuste inválido.'; end if;
  select balance into v_balance from public.players where id=p_player_id for update;
  if v_balance is null then raise exception 'Jogador não encontrado.'; end if;
  if v_balance+p_delta<0 then raise exception 'O ajuste deixaria o saldo negativo.'; end if;
  update public.players set balance=round(balance+p_delta,2),updated_at=now() where id=p_player_id returning balance into v_balance;
  insert into public.transactions(player_id,kind,amount,status,note) values(p_player_id,'adjustment',round(p_delta,2),'completed',left(trim(coalesce(p_note,'')),160));
  return jsonb_build_object('ok',true,'balance',v_balance);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_bet_summary(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  result jsonb;
  v_reset_at timestamptz;
begin
  perform public.jl_require_admin(p_token);

  select reset_at
    into v_reset_at
  from public.admin_metric_baselines
  where id = 1;

  if v_reset_at is null then
    v_reset_at := '-infinity'::timestamptz;
  end if;

  with all_bets as (
    select amount, won, payout, 'number'::text as game_type
    from public.bets
    where created_at > v_reset_at
    union all
    select amount, won, payout, 'pair'::text as game_type
    from public.pair_bets
    where created_at > v_reset_at
  )
  select jsonb_build_object(
    'total_count', count(*),
    'total_amount', coalesce(sum(amount),0),
    'pending_count', count(*) filter (where won is null),
    'pending_amount', coalesce(sum(amount) filter (where won is null),0),
    'loss_count', count(*) filter (where won is false),
    'loss_amount', coalesce(sum(amount) filter (where won is false),0),
    'win_count', count(*) filter (where won is true),
    'win_stake_amount', coalesce(sum(amount) filter (where won is true),0),
    'win_payout_amount', coalesce(sum(payout) filter (where won is true),0),
    'house_net_settled', coalesce(sum(
      case
        when won is true then amount-coalesce(payout,0)
        when won is false then amount
        else 0
      end
    ),0),
    'number_count', count(*) filter (where game_type='number'),
    'pair_count', count(*) filter (where game_type='pair'),
    'since', v_reset_at
  )
  into result
  from all_bets;

  return result;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_bonus_overview(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare player_rows jsonb; grant_rows jsonb;
begin
  perform public.jl_require_admin(p_token);

  select coalesce(jsonb_agg(x order by x.name,x.phone),'[]'::jsonb)
  into player_rows
  from (
    select p.id,p.name,p.phone,p.balance,
      coalesce(sum(g.remaining_amount) filter(where g.status='active'),0) bonus_total,
      coalesce(sum(g.remaining_amount) filter(where g.status='active' and g.game_scope in ('number','both')),0) number_bonus,
      coalesce(sum(g.remaining_amount) filter(where g.status='active' and g.game_scope in ('pair','both')),0) pair_bonus
    from public.players p
    left join public.bonus_grants g on g.player_id=p.id
    group by p.id,p.name,p.phone,p.balance
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb)
  into grant_rows
  from (
    select g.id,g.player_id,p.name,p.phone,g.game_scope,g.bonus_type,
      g.original_amount,g.remaining_amount,g.played_amount,g.status,g.note,g.created_at
    from public.bonus_grants g
    join public.players p on p.id=g.player_id
    order by g.created_at desc
    limit 150
  ) x;

  return jsonb_build_object('players',player_rows,'recent_grants',grant_rows);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_cancel_all_ludo(p_token text, p_reason text DEFAULT 'Cancelamento administrativo de emergência'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  rr record;
  v_cancelled integer:=0;
  v_refunded numeric:=0;
  v_room_refund numeric:=0;
  v_reason text:=left(coalesce(nullif(trim(p_reason),''),'Cancelamento administrativo de emergência'),220);
begin
  perform public.jl_require_admin_elevated(p_token);

  for rr in
    select id
    from public.ludo_rooms
    where status not in ('finished','cancelled')
    for update
  loop
    select coalesce(sum(stake_amount),0)
      into v_room_refund
    from public.ludo_room_players
    where room_id=rr.id and stake_paid;

    v_refunded := v_refunded + coalesce(v_room_refund,0);

    perform public.jl_ludo_refund_room(rr.id,'Reembolso administrativo: '||v_reason);

    update public.ludo_rooms
    set status='cancelled',
        action_deadline=null,
        public_challenge_expires_at=null,
        negotiation_grace_used=false,
        current_player_id=null,
        dice_result=null,
        turn_phase=null,
        updated_at=now()
    where id=rr.id;

    update public.ludo_room_players
    set status='left'
    where room_id=rr.id;

    update public.ludo_invitations
    set status='cancelled'
    where room_id=rr.id and status in ('pending','accepted');

    v_cancelled:=v_cancelled+1;
  end loop;

  delete from public.ludo_waiting_queue;

  insert into public.audit_log(action,details)
  values('ludo_admin_emergency_cancel_all',
    jsonb_build_object(
      'reason',v_reason,
      'cancelled_rooms',v_cancelled,
      'refunded_total',v_refunded,
      'performed_at',now()
    )
  );

  return jsonb_build_object(
    'ok',true,
    'message',case when v_cancelled=0 then 'Não havia jogos ativos do Ludo.' else 'Jogos do Ludo cancelados e apostas devolvidas.' end,
    'cancelled_rooms',v_cancelled,
    'refunded_total',v_refunded
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_cancel_draw_time(p_token text, p_schedule_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return public.jl_admin_cancel_game_draw_time(p_token,'number',p_schedule_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_cancel_game_draw_time(p_token text, p_game_type text, p_schedule_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_item public.draw_schedule%rowtype;
begin
  perform public.jl_require_admin(p_token);
  select * into v_item from public.draw_schedule
  where id=p_schedule_id and game_type=p_game_type
  for update;
  if v_item.id is null then raise exception 'Horário não encontrado para este jogo.'; end if;
  if v_item.status <> 'pending' then raise exception 'Somente horários futuros podem ser cancelados.'; end if;

  update public.draw_schedule set status='cancelled',updated_at=now() where id=v_item.id;
  return jsonb_build_object('ok',true,'message','Horário cancelado.');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_cancel_ludo_room(p_token text, p_room uuid, p_reason text DEFAULT 'Cancelamento administrativo de partida'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_room public.ludo_rooms%rowtype;
  v_refunded numeric := 0;
  v_reason text := left(
    coalesce(nullif(trim(p_reason), ''), 'Cancelamento administrativo de partida'),
    220
  );
begin
  perform public.jl_require_admin_elevated(p_token);

  select *
  into v_room
  from public.ludo_rooms
  where id = p_room
  for update;

  if v_room.id is null then
    raise exception 'Sala de Ludo não encontrada.';
  end if;

  if v_room.status in ('finished', 'cancelled') then
    return jsonb_build_object(
      'ok', true,
      'already_closed', true,
      'room_id', v_room.id,
      'room_code', v_room.code,
      'cancelled_rooms', 0,
      'refunded_total', 0,
      'message', 'Esta partida já estava encerrada.'
    );
  end if;

  select coalesce(sum(stake_amount), 0)
  into v_refunded
  from public.ludo_room_players
  where room_id = p_room
    and stake_paid;

  perform public.jl_ludo_refund_room(
    p_room,
    'Reembolso administrativo: ' || v_reason
  );

  update public.ludo_rooms
  set status = 'cancelled',
      action_deadline = null,
      public_challenge_expires_at = null,
      negotiation_grace_used = false,
      current_player_id = null,
      dice_result = null,
      turn_phase = null,
      updated_at = now()
  where id = p_room;

  update public.ludo_room_players
  set status = 'left'
  where room_id = p_room;

  update public.ludo_invitations
  set status = 'cancelled'
  where room_id = p_room
    and status in ('pending', 'accepted');

  delete from public.ludo_waiting_queue q
  where q.player_id in (
    select rp.player_id
    from public.ludo_room_players rp
    where rp.room_id = p_room
  );

  insert into public.audit_log(action, details)
  values(
    'ludo_admin_cancel_room',
    jsonb_build_object(
      'reason', v_reason,
      'room_id', v_room.id,
      'room_code', v_room.code,
      'previous_status', v_room.status,
      'refunded_total', v_refunded,
      'performed_at', now()
    )
  );

  return jsonb_build_object(
    'ok', true,
    'already_closed', false,
    'room_id', v_room.id,
    'room_code', v_room.code,
    'cancelled_rooms', 1,
    'refunded_total', v_refunded,
    'message', 'Partida do Ludo cancelada e apostas devolvidas.'
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_change_own_code(p_token text, p_current_code text, p_new_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_me uuid:=public.jl_admin_account_id(p_token);
  v_primary boolean:=false;
  a record;
  v_hash text;
  v_sha text:=encode(extensions.digest(coalesce(p_new_code,''),'sha256'),'hex');
begin
  if v_me is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  if not public.jl_admin_verify_account_code(v_me,p_current_code) then
    raise exception 'Código administrativo atual incorreto.';
  end if;

  if char_length(coalesce(p_new_code,''))<6 or char_length(p_new_code)>64 then
    raise exception 'O novo código administrativo deve ter entre 6 e 64 caracteres.';
  end if;
  if p_new_code=p_current_code then
    raise exception 'O novo código deve ser diferente do atual.';
  end if;

  for a in
    select id,code_hash,code_scheme
    from public.admin_accounts
    where active and id<>v_me
  loop
    if (a.code_scheme='bcrypt' and extensions.crypt(p_new_code,a.code_hash)=a.code_hash)
       or (a.code_scheme='bcrypt_sha256' and extensions.crypt(v_sha,a.code_hash)=a.code_hash) then
      raise exception 'Este código já pertence a outro administrador.';
    end if;
  end loop;

  v_hash:=extensions.crypt(p_new_code,extensions.gen_salt('bf',12));

  update public.admin_accounts
  set code_hash=v_hash,
      legacy_sha256_hash=null,
      code_scheme='bcrypt',
      updated_at=now()
  where id=v_me
  returning is_primary into v_primary;

  if v_primary then
    update public.admin_config
    set code_hash=v_hash,updated_at=now();
  end if;

  update public.admin_sessions
  set elevated_until=now()+interval '10 minutes'
  where admin_id=v_me and token_hash=public.jl_token_hash(p_token);

  return jsonb_build_object('ok',true,'message','Código administrativo alterado com segurança.');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_clear_draw_schedule(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return public.jl_admin_clear_game_schedule(p_token,'number');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_clear_game_schedule(p_token text, p_game_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_count integer:=0;
begin
  perform public.jl_require_admin(p_token);
  if p_game_type not in ('number','pair') then raise exception 'Jogo inválido.'; end if;
  update public.draw_schedule
  set status='cancelled',updated_at=now()
  where game_type=p_game_type and status='pending';
  get diagnostics v_count=row_count;
  return jsonb_build_object('ok',true,'cancelled',v_count,'message',v_count||' horário(s) cancelado(s).');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_close_game_round(p_token text, p_game_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_round public.game_rounds%rowtype;
begin
  perform public.jl_require_admin(p_token);
  if p_game_type not in ('number','pair') then raise exception 'Jogo inválido.'; end if;

  select * into v_round
  from public.game_rounds
  where game_type=p_game_type and status in ('open','locked','closed')
  order by opened_at desc limit 1 for update;

  if v_round.id is null then raise exception 'Não há rodada ativa para este jogo.'; end if;

  update public.game_rounds
  set status='locked',closed_at=now(),closes_at=least(closes_at,now()),draw_at=now()
  where id=v_round.id;

  perform public.jl_finalize_game_due_rounds(p_game_type);
  perform public.jl_process_game(p_game_type);

  return jsonb_build_object('ok',true,'game_type',p_game_type,'round_no',v_round.round_no,'message','Rodada encerrada e sorteada.');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_close_round(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return public.jl_admin_close_game_round(p_token,'number');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_create_account(p_token text, p_display_name text, p_role text, p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_name text:=regexp_replace(trim(coalesce(p_display_name,'')),'[[:space:]]+',' ','g');
  v_role text:=lower(trim(coalesce(p_role,'')));
  a record;
  v_id uuid;
  v_sha text:=encode(extensions.digest(coalesce(p_code,''),'sha256'),'hex');
begin
  perform public.jl_require_super_admin(p_token);
  perform public.jl_require_admin_elevated(p_token);

  if char_length(v_name)<2 or char_length(v_name)>80 then
    raise exception 'O nome do administrador deve ter entre 2 e 80 caracteres.';
  end if;
  if v_role not in ('admin','super_admin') then
    raise exception 'Função administrativa inválida.';
  end if;
  if char_length(coalesce(p_code,''))<6 or char_length(p_code)>64 then
    raise exception 'O código administrativo deve ter entre 6 e 64 caracteres.';
  end if;

  for a in
    select id,code_hash,code_scheme
    from public.admin_accounts
    where active
  loop
    if (a.code_scheme='bcrypt' and extensions.crypt(p_code,a.code_hash)=a.code_hash)
       or (a.code_scheme='bcrypt_sha256' and extensions.crypt(v_sha,a.code_hash)=a.code_hash) then
      raise exception 'Este código já pertence a outro administrador.';
    end if;
  end loop;

  insert into public.admin_accounts(display_name,role,code_hash,code_scheme,active)
  values(v_name,v_role,extensions.crypt(p_code,extensions.gen_salt('bf',12)),'bcrypt',true)
  returning id into v_id;

  return jsonb_build_object('ok',true,'id',v_id,'name',v_name,'role',v_role);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_create_influencer(p_token text, p_name text, p_phone text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_name text := regexp_replace(trim(coalesce(p_name,'')),'\s+',' ','g');
  v_phone text := nullif(public.jl_phone(coalesce(p_phone,'')),'');
  v_code text;
  v_row public.influencers%rowtype;
  v_try int;
begin
  perform public.jl_require_admin(p_token);

  if char_length(v_name) < 2 or char_length(v_name) > 80 then
    raise exception 'Informe o nome do influenciador entre 2 e 80 caracteres.';
  end if;
  if v_phone is not null and (char_length(v_phone) < 8 or char_length(v_phone) > 15) then
    raise exception 'Número de telefone do influenciador inválido.';
  end if;

  for v_try in 1..12 loop
    v_code := 'JL-' || upper(encode(extensions.gen_random_bytes(4),'hex'));
    begin
      insert into public.influencers(name,phone,code)
      values(v_name,v_phone,v_code)
      returning * into v_row;
      exit;
    exception
      when unique_violation then
        v_row.id := null;
    end;
  end loop;

  if v_row.id is null then
    raise exception 'Não foi possível gerar um código único. Tente novamente.';
  end if;

  return jsonb_build_object(
    'message','Influenciador registado e código gerado.',
    'influencer',jsonb_build_object(
      'id',v_row.id,
      'name',v_row.name,
      'phone',v_row.phone,
      'code',v_row.code,
      'active',v_row.active,
      'created_at',v_row.created_at
    )
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_dashboard(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_number jsonb;
  v_pair jsonb;
  v_deposits jsonb;
  v_withdrawals jsonb;
  v_players jsonb;
begin
  perform public.jl_require_admin(p_token);
  perform public.jl_process_game_engine();

  v_number:=public.jl_admin_game_snapshot('number');
  v_pair:=public.jl_admin_game_snapshot('pair');

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb)
  into v_deposits
  from (
    select d.id,d.amount,d.note,d.status,d.created_at,p.name,p.phone
    from public.deposit_requests d
    join public.players p on p.id=d.player_id
    where d.status='pending'
    order by d.created_at desc
    limit 100
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb)
  into v_withdrawals
  from (
    select w.id,w.amount,w.status,w.reason,w.user_note,w.created_at,p.name,p.phone,
           public.jl_deposit_wager_locked(w.player_id) deposit_locked,
           greatest(0,p.balance-public.jl_deposit_wager_locked(w.player_id)) withdrawable_balance
    from public.withdrawal_requests w
    join public.players p on p.id=w.player_id
    where w.status='pending'
      and p.deleted_at is null
    order by w.created_at desc
    limit 100
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb)
  into v_players
  from (
    select p.id,p.name,p.phone,p.balance,p.blocked,p.created_at,
           public.jl_deposit_wager_locked(p.id) deposit_locked,
           greatest(0,p.balance-public.jl_deposit_wager_locked(p.id)) withdrawable_balance
    from public.players p
    where p.deleted_at is null
    order by p.created_at desc
    limit 200
  ) x;

  return jsonb_build_object(
    'server_time',now(),
    'games',jsonb_build_object('number',v_number,'pair',v_pair),
    'pending_deposits',v_deposits,
    'pending_withdrawals',v_withdrawals,
    'players',v_players
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_delete_player(p_token text, p_player_id uuid, p_admin_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_hash text;
  v_name text;
begin
  perform public.jl_require_admin(p_token);
  if not public.jl_admin_verify_code_for_token(p_token,p_admin_pin) then
    raise exception 'PIN administrativo incorreto.';
  end if;

  select name into v_name
  from public.players
  where id=p_player_id and deleted_at is null
  for update;

  if v_name is null then raise exception 'Jogador não encontrado.'; end if;

  if exists(
    select 1
    from public.ludo_room_players rp
    join public.ludo_rooms r on r.id=rp.room_id
    where rp.player_id=p_player_id
      and rp.status<>'left'
      and r.status in ('funding','playing')
  ) then
    raise exception 'O jogador está numa partida de Ludo ativa. Cancele/termine a partida antes de eliminar a conta.';
  end if;

  delete from public.player_sessions where player_id=p_player_id;
  delete from public.customer_support_messages where player_id=p_player_id;
  update public.pin_recovery_requests
    set status='cancelled',otp_hash=null,otp_expires_at=null,updated_at=now()
  where player_id=p_player_id and status in ('pending_admin','sending','code_sent');

  update public.ludo_waiting_queue set expires_at=now() where player_id=p_player_id;
  update public.ludo_invitations set status='cancelled'
  where target_player_id=p_player_id and status='pending';

  update public.players
  set name='Conta eliminada',
      phone='deleted-'||replace(id::text,'-',''),
      pin_hash=extensions.crypt(encode(extensions.gen_random_bytes(24),'hex'),extensions.gen_salt('bf',10)),
      blocked=true,
      deleted_at=now(),
      deleted_by_admin=true,
      updated_at=now()
  where id=p_player_id;

  insert into public.audit_log(action,details)
  values('admin_delete_player',
         jsonb_build_object('player_id',p_player_id,'previous_name',v_name,'at',now(),'mode','anonymized_preserve_financial_audit'));

  return jsonb_build_object(
    'ok',true,
    'message','Conta eliminada e anonimizada. O histórico financeiro foi preservado para auditoria.'
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_draw_round(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform public.jl_require_admin(p_token);
  raise exception 'O sorteio é automático na hora definida para encerramento da rodada.';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_financial_summary(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  b public.admin_metric_baselines%rowtype;
  v_players_balance numeric := 0;
  v_player_count integer := 0;
  v_number numeric := 0;
  v_pair numeric := 0;
  v_ludo numeric := 0;
  v_number_house numeric := 0;
  v_pair_house numeric := 0;
  v_ludo_commission numeric := 0;
begin
  perform public.jl_require_admin(p_token);

  select * into b
  from public.admin_metric_baselines
  where id = 1;

  select coalesce(sum(balance), 0), count(*)
    into v_players_balance, v_player_count
  from public.players
  where deleted_at is null;

  select coalesce(sum(amount), 0)
    into v_number
  from public.bets
  where created_at > b.reset_at;

  select coalesce(sum(amount), 0)
    into v_pair
  from public.pair_bets
  where created_at > b.reset_at;

  select coalesce(-sum(amount) filter (where amount < 0), 0)
    into v_ludo
  from public.transactions
  where kind in ('ludo_stake', 'ludo_reentry')
    and created_at > b.reset_at;

  select coalesce(sum(bt.amount - bt.payout), 0)
    into v_number_house
  from public.bets bt
  join public.game_rounds r on r.id = bt.round_id
  where r.game_type = 'number'
    and r.status = 'published'
    and bt.created_at > b.reset_at;

  select coalesce(sum(pb.amount - pb.payout), 0)
    into v_pair_house
  from public.pair_bets pb
  join public.game_rounds r on r.id = pb.round_id
  where r.game_type = 'pair'
    and r.status = 'published'
    and pb.created_at > b.reset_at;

  select coalesce(sum(lp.commission), 0)
    into v_ludo_commission
  from public.ludo_payouts lp
  join public.ludo_rooms lr on lr.id = lp.room_id
  where lp.created_at > b.reset_at
    and lr.created_at > b.reset_at;

  return jsonb_build_object(
    'player_balance_total', round(v_players_balance, 2),
    'user_balance_total', round(v_players_balance, 2),
    'player_count', v_player_count,
    'number_total', round(v_number, 2),
    'pair_total', round(v_pair, 2),
    'ludo_total', round(v_ludo, 2),
    'games_total', round(v_number + v_pair + v_ludo, 2),
    'number_house', round(v_number_house, 2),
    'pair_house', round(v_pair_house, 2),
    'ludo_commission', round(v_ludo_commission, 2),
    'house_total', round(v_number_house + v_pair_house + v_ludo_commission, 2),
    'since', b.reset_at
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_force_logout_player(p_token text, p_player_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_count integer:=0;
begin
  perform public.jl_require_admin(p_token);
  if not exists(select 1 from public.players where id=p_player_id and deleted_at is null) then
    raise exception 'Jogador não encontrado.';
  end if;
  delete from public.player_sessions where player_id=p_player_id;
  get diagnostics v_count=row_count;
  insert into public.audit_log(action,details)
  values('admin_force_logout_player',jsonb_build_object('player_id',p_player_id,'sessions',v_count,'at',now()));
  return jsonb_build_object('ok',true,'sessions_closed',v_count,'message','Sessões do jogador encerradas.');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_game_snapshot(p_game_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_round public.game_rounds%rowtype;
  v_last public.game_rounds%rowtype;
  v_settings public.game_settings%rowtype;
  v_schedule jsonb;
  v_stats jsonb;
  v_recent jsonb;
  v_total numeric := 0;
  v_min_exposure numeric := 0;
  v_safe_count integer := 0;
  v_outcome_count integer := 0;
begin
  select * into v_settings from public.game_settings where game_type=p_game_type;
  select * into v_round from public.game_rounds
    where game_type=p_game_type and status in ('open','locked','closed')
    order by opened_at desc limit 1;
  select * into v_last from public.game_rounds
    where game_type=p_game_type and status='published'
    order by published_at desc nulls last,opened_at desc limit 1;

  select coalesce(jsonb_agg(x order by x.draw_at),'[]'::jsonb) into v_schedule
  from (
    select id,draw_at,status,round_id,created_at
    from public.draw_schedule
    where game_type=p_game_type and status in ('pending','active')
    order by draw_at limit 250
  ) x;

  if p_game_type='number' then
    v_outcome_count := 11;
    select coalesce(sum(amount),0) into v_total from public.bets where round_id=v_round.id;

    select coalesce(jsonb_agg(jsonb_build_object(
      'number',n,'bets',coalesce(s.bet_count,0),'total',coalesce(s.total,0)
    ) order by n),'[]'::jsonb) into v_stats
    from generate_series(0,10) n
    left join (
      select selected_number,count(*)::int bet_count,sum(amount)::numeric total
      from public.bets where round_id=v_round.id group by selected_number
    ) s on s.selected_number=n;

    select coalesce(min(exposure),0),
           case when v_total=0 then 11 else count(*) filter (where exposure*v_settings.multiplier < v_total) end
    into v_min_exposure,v_safe_count
    from (
      select n,coalesce(sum(b.amount),0) exposure
      from generate_series(0,10) n
      left join public.bets b on b.round_id=v_round.id and b.selected_number=n
      group by n
    ) e;

    select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_recent
    from (
      select b.id,b.selected_number,b.amount,b.won,b.payout,b.created_at,p.name,p.phone,r.round_no
      from public.bets b join public.players p on p.id=b.player_id join public.game_rounds r on r.id=b.round_id
      order by b.created_at desc limit 100
    ) x;
  else
    v_outcome_count := 55;
    select coalesce(sum(amount),0) into v_total from public.pair_bets where round_id=v_round.id;

    select coalesce(jsonb_agg(jsonb_build_object(
      'number_a',c.a,'number_b',c.b,'bets',coalesce(s.bet_count,0),'total',coalesce(s.total,0)
    ) order by c.a,c.b),'[]'::jsonb) into v_stats
    from (
      select a,b from generate_series(0,10) a cross join generate_series(0,10) b where a<b
    ) c
    left join (
      select number_a,number_b,count(*)::int bet_count,sum(amount)::numeric total
      from public.pair_bets where round_id=v_round.id group by number_a,number_b
    ) s on s.number_a=c.a and s.number_b=c.b;

    select coalesce(min(exposure),0),
           case when v_total=0 then 55 else count(*) filter (where exposure*v_settings.multiplier < v_total) end
    into v_min_exposure,v_safe_count
    from (
      select a,b,coalesce(sum(pb.amount),0) exposure
      from generate_series(0,10) a
      cross join generate_series(0,10) b
      left join public.pair_bets pb on pb.round_id=v_round.id and pb.number_a=a and pb.number_b=b
      where a<b
      group by a,b
    ) e;

    select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_recent
    from (
      select pb.id,pb.number_a,pb.number_b,pb.amount,pb.won,pb.payout,pb.created_at,p.name,p.phone,r.round_no
      from public.pair_bets pb join public.players p on p.id=pb.player_id join public.game_rounds r on r.id=pb.round_id
      order by pb.created_at desc limit 100
    ) x;
  end if;

  return jsonb_build_object(
    'game_type',p_game_type,
    'settings',to_jsonb(v_settings),
    'round',case when v_round.id is null then null else jsonb_build_object(
      'id',v_round.id,'round_no',v_round.round_no,'status',v_round.status,
      'opened_at',v_round.opened_at,'closes_at',v_round.closes_at,
      'draw_at',v_round.draw_at,'schedule_id',v_round.schedule_id
    ) end,
    'last_result',case when v_last.id is null then null else jsonb_build_object(
      'round_no',v_last.round_no,'drawn_number',v_last.drawn_number,
      'pair_drawn_a',v_last.pair_drawn_a,'pair_drawn_b',v_last.pair_drawn_b,
      'drawn_at',v_last.drawn_at,'published_at',v_last.published_at
    ) end,
    'financial',jsonb_build_object(
      'outcome_count',v_outcome_count,
      'total_staked',v_total,
      'min_exposure',v_min_exposure,
      'payout_at_min',round(v_min_exposure*v_settings.multiplier,2),
      'house_floor_at_min',round(v_total-(v_min_exposure*v_settings.multiplier),2),
      'safe_outcomes',v_safe_count
    ),
    'stats',v_stats,'schedule',v_schedule,'recent_bets',v_recent
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_grant_bonus(p_token text, p_player_ids uuid[], p_game_scope text, p_bonus_type text, p_amount numeric, p_note text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  granted_count int:=0;
  total_amount numeric:=0;
begin
  perform public.jl_require_admin(p_token);

  if p_game_scope not in ('number','pair','both') then raise exception 'Jogo do bónus inválido.'; end if;
  if p_bonus_type not in ('promotional','welcome','loyalty','compensation','manual') then raise exception 'Tipo de bónus inválido.'; end if;
  if p_amount is null or p_amount<1 or p_amount>1000000 or p_amount<>trunc(p_amount) then
    raise exception 'O bónus deve ser um valor inteiro entre 1 e 1.000.000 MZN.';
  end if;
  if p_player_ids is null or coalesce(array_length(p_player_ids,1),0)=0 then raise exception 'Selecione pelo menos um jogador.'; end if;
  if array_length(p_player_ids,1)>200 then raise exception 'Selecione no máximo 200 jogadores por distribuição.'; end if;

  insert into public.bonus_grants(player_id,game_scope,bonus_type,original_amount,remaining_amount,note)
  select distinct p.id,p_game_scope,p_bonus_type,p_amount,p_amount,left(trim(coalesce(p_note,'')),160)
  from public.players p
  where p.id=any(p_player_ids)
  on conflict do nothing;

  get diagnostics granted_count=row_count;
  total_amount:=granted_count*p_amount;

  if granted_count=0 then raise exception 'Nenhum jogador válido selecionado.'; end if;

  insert into public.audit_log(action,details)
  values('bonus.distributed',jsonb_build_object(
    'game_scope',p_game_scope,
    'bonus_type',p_bonus_type,
    'amount_each',p_amount,
    'players',granted_count,
    'total_amount',total_amount,
    'note',left(trim(coalesce(p_note,'')),160),
    'created_at',now()
  ));

  return jsonb_build_object(
    'ok',true,
    'players',granted_count,
    'amount_each',p_amount,
    'total_amount',total_amount,
    'game_scope',p_game_scope,
    'bonus_type',p_bonus_type
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_influencers(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_rows jsonb;
  v_total_players bigint;
  v_referred bigint;
begin
  perform public.jl_require_admin(p_token);

  select count(*) into v_total_players
  from public.players p
  where p.deleted_at is null;

  select count(*) into v_referred
  from public.influencer_referrals r
  join public.players p on p.id=r.player_id
  where p.deleted_at is null;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb)
    into v_rows
  from (
    select
      i.id,
      i.name,
      i.phone,
      i.code,
      i.active,
      i.created_at,
      i.updated_at,
      (
        select count(*)
        from public.influencer_referrals r
        join public.players p on p.id=r.player_id
        where r.influencer_id=i.id
          and p.deleted_at is null
      ) as referral_count,
      (
        select coalesce(jsonb_agg(jsonb_build_object(
          'player_id',p.id,
          'name',p.name,
          'phone',p.phone,
          'player_created_at',p.created_at,
          'referred_at',r.created_at,
          'code_used',r.code_used
        ) order by r.created_at desc),'[]'::jsonb)
        from public.influencer_referrals r
        join public.players p on p.id=r.player_id
        where r.influencer_id=i.id
          and p.deleted_at is null
      ) as registrations
    from public.influencers i
  ) x;

  return jsonb_build_object(
    'influencers',v_rows,
    'influencer_count',(select count(*) from public.influencers),
    'active_influencer_count',(select count(*) from public.influencers where active),
    'referred_players',v_referred,
    'without_invite_code',greatest(v_total_players-v_referred,0),
    'total_players',v_total_players
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_issue_recovery_code(p_token text, p_request_id uuid, p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  r public.pin_recovery_requests%rowtype;
  pname text;
  v_expires_at timestamptz;
begin
  perform public.jl_require_admin(p_token);

  if coalesce(p_code,'') !~ '^[0-9]{6}$' then
    raise exception 'Código de recuperação inválido.';
  end if;

  select * into r
  from public.pin_recovery_requests
  where id=p_request_id
  for update;

  if r.id is null then raise exception 'Pedido não encontrado.'; end if;
  if r.status not in ('pending_admin','code_sent','expired') then
    raise exception 'Este pedido não pode receber um novo código neste estado.';
  end if;

  select name into pname
  from public.players
  where id=r.player_id
    and deleted_at is null;

  if pname is null then raise exception 'Conta indisponível.'; end if;

  v_expires_at:=now()+interval '24 hours';

  update public.pin_recovery_requests
  set status='code_sent',
      otp_hash=extensions.crypt(p_code,extensions.gen_salt('bf',10)),
      otp_expires_at=v_expires_at,
      otp_attempts=0,
      approved_at=coalesce(approved_at,now()),
      sent_at=now(),
      updated_at=now()
  where id=r.id;

  insert into public.audit_log(action,details)
  values(
    'admin_issue_pin_recovery_code',
    jsonb_build_object(
      'request_id',r.id,
      'player_id',r.player_id,
      'expires_at',v_expires_at
    )
  );

  return jsonb_build_object(
    'ok',true,
    'request_id',r.id,
    'name',pname,
    'phone',r.phone,
    'expires_at',v_expires_at,
    'message','Código criado. Envie-o ao jogador por um canal confirmado.'
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_list_accounts(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform public.jl_require_super_admin(p_token);

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',id,
      'name',display_name,
      'role',role,
      'active',active,
      'is_primary',is_primary,
      'created_at',created_at,
      'updated_at',updated_at,
      'last_login_at',last_login_at
    ) order by is_primary desc,created_at)
    from public.admin_accounts
  ),'[]'::jsonb);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_login(p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_admin public.admin_accounts%rowtype;
  v_candidate uuid;
  v_token text;
  v_headers jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  v_ip text;
  v_country text;
  v_agent text;
  v_source text;
  v_key text;
  v_rate public.login_rate_limits%rowtype;
  v_failed integer;
  v_level integer;
  v_minutes integer;
  v_retry integer;
  v_unseen integer := 0;
  v_last_alert public.admin_login_alerts%rowtype;
  v_sha text;
begin
  v_ip := nullif(btrim(split_part(coalesce(v_headers->>'x-forwarded-for',''), ',', 1)), '');
  if v_ip is null then v_ip := nullif(v_headers->>'cf-connecting-ip',''); end if;
  if v_ip is null then v_ip := nullif(v_headers->>'x-real-ip',''); end if;

  v_country := coalesce(
    nullif(v_headers->>'cf-ipcountry',''),
    nullif(v_headers->>'x-vercel-ip-country',''),
    nullif(v_headers->>'x-country-code','')
  );
  v_agent := nullif(v_headers->>'user-agent','');
  v_source := coalesce(v_ip,v_agent,'unknown');
  v_key := encode(extensions.digest(v_source,'sha256'),'hex');

  insert into public.login_rate_limits(scope,subject_key)
  values('admin',v_key)
  on conflict(scope,subject_key) do nothing;

  select * into v_rate
  from public.login_rate_limits
  where scope='admin' and subject_key=v_key
  for update;

  if v_rate.last_failed_at is not null
     and v_rate.last_failed_at < now()-interval '24 hours'
     and coalesce(v_rate.blocked_until,'-infinity'::timestamptz)<=now() then
    update public.login_rate_limits
    set failed_attempts=0,block_level=0,blocked_until=null,updated_at=now()
    where scope='admin' and subject_key=v_key;
    v_rate.failed_attempts:=0;
    v_rate.block_level:=0;
    v_rate.blocked_until:=null;
  end if;

  if v_rate.blocked_until is not null and v_rate.blocked_until>now() then
    v_retry:=greatest(1,ceil(extract(epoch from (v_rate.blocked_until-now()))/60.0)::integer);
    perform set_config('response.status','429',true);
    return jsonb_build_object(
      'ok',false,
      'message',format('Acesso administrativo temporariamente limitado. Tente novamente em %s minuto(s).',v_retry),
      'retry_after_minutes',v_retry
    );
  end if;

  v_sha:=encode(extensions.digest(coalesce(p_code,''),'sha256'),'hex');

  select id into v_candidate
  from public.admin_accounts
  where active and legacy_sha256_hash=v_sha
  order by is_primary desc,created_at
  limit 1;

  if v_candidate is null then
    for v_admin in
      select *
      from public.admin_accounts
      where active and code_hash is not null
      order by is_primary desc,created_at
    loop
      if (v_admin.code_scheme='bcrypt' and extensions.crypt(coalesce(p_code,''),v_admin.code_hash)=v_admin.code_hash) or (v_admin.code_scheme='bcrypt_sha256' and extensions.crypt(v_sha,v_admin.code_hash)=v_admin.code_hash) then
        v_candidate:=v_admin.id;
        exit;
      end if;
    end loop;
  end if;

  if v_candidate is null or not public.jl_admin_verify_account_code(v_candidate,p_code) then
    v_failed:=coalesce(v_rate.failed_attempts,0)+1;

    if v_failed>=3 then
      v_level:=coalesce(v_rate.block_level,0)+1;
      v_minutes:=case v_level
        when 1 then 15
        when 2 then 30
        when 3 then 60
        when 4 then 120
        when 5 then 240
        when 6 then 480
        when 7 then 960
        else 1440
      end;

      update public.login_rate_limits
      set failed_attempts=0,
          block_level=v_level,
          blocked_until=now()+make_interval(mins=>v_minutes),
          last_failed_at=now(),
          updated_at=now()
      where scope='admin' and subject_key=v_key;

      insert into public.admin_login_alerts(
        failed_attempts,block_level,blocked_until,ip_address,country_code,user_agent
      ) values(
        3,v_level,now()+make_interval(mins=>v_minutes),v_ip,v_country,v_agent
      );

      insert into public.audit_log(action,details)
      values('admin_login_rate_limited',jsonb_build_object(
        'failed_attempts',3,
        'block_level',v_level,
        'blocked_minutes',v_minutes,
        'ip_address',v_ip,
        'country_code',v_country,
        'user_agent',v_agent
      ));

      perform set_config('response.status','429',true);
      return jsonb_build_object(
        'ok',false,
        'message',format('Acesso administrativo temporariamente limitado. Tente novamente em %s minuto(s).',v_minutes),
        'retry_after_minutes',v_minutes
      );
    end if;

    update public.login_rate_limits
    set failed_attempts=v_failed,last_failed_at=now(),updated_at=now()
    where scope='admin' and subject_key=v_key;

    perform set_config('response.status','401',true);
    return jsonb_build_object(
      'ok',false,
      'message','Código administrativo incorreto.',
      'attempts_remaining',3-v_failed
    );
  end if;

  select * into v_admin
  from public.admin_accounts
  where id=v_candidate and active;

  delete from public.login_rate_limits
  where scope='admin' and subject_key=v_key;

  select count(*)::integer into v_unseen
  from public.admin_login_alerts
  where seen_at is null;

  if v_unseen>0 then
    select * into v_last_alert
    from public.admin_login_alerts
    where seen_at is null
    order by created_at desc
    limit 1;

    update public.admin_login_alerts
    set seen_at=now()
    where seen_at is null;
  end if;

  v_token:=encode(extensions.gen_random_bytes(32),'hex');

  insert into public.admin_sessions(
    admin_id,token_hash,expires_at,elevated_until,ip_address,user_agent
  ) values(
    v_admin.id,
    public.jl_token_hash(v_token),
    now()+interval '12 hours',
    now()+interval '10 minutes',
    v_ip,
    v_agent
  );

  update public.admin_accounts
  set last_login_at=now(),updated_at=now()
  where id=v_admin.id;

  return jsonb_build_object(
    'ok',true,
    'token',v_token,
    'expires_in_hours',12,
    'elevated_for_minutes',10,
    'admin',jsonb_build_object(
      'id',v_admin.id,
      'name',v_admin.display_name,
      'role',v_admin.role
    ),
    'security_alert',
      case when v_unseen>0 then jsonb_build_object(
        'count',v_unseen,
        'created_at',v_last_alert.created_at,
        'ip_address',v_last_alert.ip_address,
        'country_code',v_last_alert.country_code,
        'failed_attempts',v_last_alert.failed_attempts,
        'blocked_until',v_last_alert.blocked_until
      ) else null end
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_logout(p_token text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  delete from public.admin_sessions where token_hash=public.jl_token_hash(p_token);
  return true;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_ludo_active_rooms(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_rooms jsonb;
begin
  if not public.jl_admin_ok(p_token) then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', r.id,
        'code', r.code,
        'status', r.status,
        'mode', r.mode,
        'player_count', r.player_count,
        'bet_amount', r.bet_amount,
        'pot', r.pot,
        'created_at', r.created_at,
        'active_players', (
          select count(*)
          from public.ludo_room_players rp
          where rp.room_id = r.id
            and rp.status <> 'left'
        ),
        'staked_total', (
          select coalesce(sum(rp.stake_amount), 0)
          from public.ludo_room_players rp
          where rp.room_id = r.id
            and rp.stake_paid
        )
      )
      order by r.created_at desc
    ),
    '[]'::jsonb
  )
  into v_rooms
  from public.ludo_rooms r
  where r.status not in ('finished', 'cancelled');

  return v_rooms;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_ludo_emergency_status(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_rooms integer;
  v_players integer;
  v_staked numeric;
begin
  if not public.jl_admin_ok(p_token) then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  select count(*) into v_rooms
  from public.ludo_rooms
  where status not in ('finished','cancelled');

  select count(distinct rp.player_id),
         coalesce(sum(case when rp.stake_paid then rp.stake_amount else 0 end),0)
  into v_players, v_staked
  from public.ludo_room_players rp
  join public.ludo_rooms r on r.id=rp.room_id
  where r.status not in ('finished','cancelled')
    and rp.status <> 'left';

  return jsonb_build_object(
    'active_rooms',v_rooms,
    'active_players',v_players,
    'staked_total',v_staked,
    'waiting_queue',(select count(*) from public.ludo_waiting_queue)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_mark_recovery_sent(p_token text, p_request_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform public.jl_require_admin(p_token);
  update public.pin_recovery_requests
  set status='code_sent',sent_at=now(),updated_at=now()
  where id=p_request_id and status='sending';
  if not found then raise exception 'Pedido não está pronto para envio.'; end if;
  return true;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_ok(p_token text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
begin
  return public.jl_admin_account_id(p_token) is not null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_open_game_round(p_token text, p_game_type text, p_draw_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_round public.game_rounds%rowtype;
  v_settings public.game_settings%rowtype;
begin
  perform public.jl_require_admin(p_token);
  perform public.jl_process_game(p_game_type);
  select * into v_settings from public.game_settings where game_type=p_game_type;
  if v_settings.game_type is null then raise exception 'Jogo inválido.'; end if;
  if not v_settings.enabled then raise exception 'Este jogo está desativado.'; end if;

  if p_draw_at is null
     or p_draw_at <= now() + make_interval(secs => greatest(10,v_settings.lock_seconds+2))
     or p_draw_at > now()+interval '7 days' then
    raise exception 'Defina um sorteio válido entre alguns segundos e 7 dias a partir de agora.';
  end if;

  if exists(
    select 1 from public.game_rounds
    where game_type=p_game_type and status in ('open','locked','closed','drawn')
  ) then
    raise exception 'Finalize a rodada atual deste jogo antes de abrir outra.';
  end if;

  insert into public.game_rounds(game_type,status,closes_at,draw_at)
  values(p_game_type,'open',p_draw_at-make_interval(secs=>v_settings.lock_seconds),p_draw_at)
  returning * into v_round;

  return jsonb_build_object(
    'ok',true,'game_type',p_game_type,'round_no',v_round.round_no,
    'closes_at',v_round.closes_at,'draw_at',v_round.draw_at,
    'message','Rodada aberta para '||case when p_game_type='number' then 'Número Lendário' else 'Dupla Lendária' end||'.'
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_open_round(p_token text, p_closes_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return public.jl_admin_open_game_round(p_token,'number',p_closes_at);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_prepare_recovery_send(p_token text, p_request_id uuid, p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  r public.pin_recovery_requests%rowtype;
  pname text;
  v_expires_at timestamptz;
begin
  perform public.jl_require_admin(p_token);

  if coalesce(p_code,'') !~ '^[0-9]{6}$' then
    raise exception 'Código de recuperação inválido.';
  end if;

  select * into r
  from public.pin_recovery_requests
  where id=p_request_id
  for update;

  if r.id is null then raise exception 'Pedido não encontrado.'; end if;
  if r.status<>'pending_admin' then
    raise exception 'Este pedido já foi processado.';
  end if;

  select name into pname
  from public.players
  where id=r.player_id
    and deleted_at is null;

  if pname is null then raise exception 'Conta indisponível.'; end if;
  if r.recovery_email is null then
    raise exception 'Este pedido não possui e-mail de recuperação.';
  end if;

  v_expires_at:=now()+interval '24 hours';

  update public.pin_recovery_requests
  set status='sending',
      otp_hash=extensions.crypt(p_code,extensions.gen_salt('bf',10)),
      otp_expires_at=v_expires_at,
      otp_attempts=0,
      approved_at=now(),
      updated_at=now()
  where id=r.id;

  return jsonb_build_object(
    'ok',true,
    'request_id',r.id,
    'email',r.recovery_email,
    'phone',r.phone,
    'name',pname,
    'expires_at',v_expires_at
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_publish_round(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform public.jl_require_admin(p_token);
  raise exception 'A publicação do resultado é automática junto com o sorteio.';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_reauthenticate(p_token text, p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_admin uuid:=public.jl_admin_account_id(p_token);
  v_until timestamptz;
begin
  if v_admin is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  if not public.jl_admin_verify_account_code(v_admin,p_code) then
    raise exception 'Código administrativo incorreto.';
  end if;

  v_until:=now()+interval '10 minutes';

  update public.admin_sessions
  set elevated_until=v_until
  where token_hash=public.jl_token_hash(p_token)
    and admin_id=v_admin
    and expires_at>now();

  return jsonb_build_object(
    'ok',true,
    'elevated_until',v_until,
    'message','Autenticação reforçada confirmada por 10 minutos.'
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_recent_audit(p_token text, p_limit integer DEFAULT 80)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_limit integer:=least(200,greatest(1,coalesce(p_limit,80)));
  v_rows jsonb;
begin
  perform public.jl_require_admin(p_token);

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb)
  into v_rows
  from (
    select
      id,action,details,created_at,
      actor_admin_id,actor_session_id,actor_name,actor_role,
      target_type,target_id,before_state,after_state
    from public.audit_log
    order by created_at desc
    limit v_limit
  ) x;

  return v_rows;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_recovery_requests(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare rows jsonb;
begin
  perform public.jl_require_admin(p_token);

  update public.pin_recovery_requests
  set status='expired',updated_at=now()
  where status='code_sent'
    and otp_expires_at is not null
    and otp_expires_at<=now();

  select coalesce(jsonb_agg(x order by x.requested_at desc),'[]'::jsonb)
  into rows
  from (
    select
      r.id,r.status,r.phone,r.recovery_email,r.requested_at,
      r.approved_at,r.sent_at,r.otp_expires_at,r.completed_at,r.rejected_at,
      coalesce(p.name,'Conta não localizada') as name,
      p.id as player_id,
      (p.id is not null) as account_found
    from public.pin_recovery_requests r
    left join public.players p on p.id=r.player_id and p.deleted_at is null
    where r.status in ('pending_admin','sending','code_sent')
       or r.requested_at>=now()-interval '2 days'
    order by r.requested_at desc
    limit 150
  ) x;

  return rows;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_recovery_send_failed(p_token text, p_request_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform public.jl_require_admin(p_token);
  update public.pin_recovery_requests
  set status='pending_admin',
      otp_hash=null,otp_expires_at=null,otp_attempts=0,
      approved_at=null,updated_at=now()
  where id=p_request_id and status='sending';
  return true;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_reject_recovery(p_token text, p_request_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform public.jl_require_admin(p_token);
  update public.pin_recovery_requests
  set status='rejected',rejected_at=now(),updated_at=now(),
      otp_hash=null,otp_expires_at=null
  where id=p_request_id and status in ('pending_admin','sending');
  if not found then raise exception 'Pedido não pode ser rejeitado neste estado.'; end if;
  return true;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_reset_financial_counters(p_token text, p_admin_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_hash text;
  v_reset_at timestamptz := clock_timestamp();
begin
  perform public.jl_require_admin(p_token);

  if not public.jl_admin_verify_code_for_token(p_token,p_admin_pin) then
    raise exception 'PIN administrativo incorreto.';
  end if;

  insert into public.admin_metric_baselines(
    id, number_total, pair_total, ludo_total,
    number_house, pair_house, ludo_commission, reset_at
  )
  values(1, 0, 0, 0, 0, 0, 0, v_reset_at)
  on conflict (id) do update set
    number_total = 0,
    pair_total = 0,
    ludo_total = 0,
    number_house = 0,
    pair_house = 0,
    ludo_commission = 0,
    reset_at = excluded.reset_at;

  insert into public.audit_log(action, details)
  values(
    'admin_reset_financial_counters',
    jsonb_build_object(
      'mode', 'timestamp_cutoff',
      'reset_at', v_reset_at,
      'at', now()
    )
  );

  return jsonb_build_object(
    'ok', true,
    'reset_at', v_reset_at,
    'message', 'Contagem reiniciada de forma permanente. Dados anteriores não voltarão ao atualizar.'
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_review_deposit(p_token text, p_request_id uuid, p_decision text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_req public.deposit_requests%rowtype;
begin
  perform public.jl_require_admin_elevated(p_token);

  if p_decision not in ('approved','rejected') then
    raise exception 'Decisão inválida.';
  end if;

  select * into v_req
  from public.deposit_requests
  where id=p_request_id
  for update;

  if v_req.id is null or v_req.status<>'pending' then
    raise exception 'Pedido de depósito não está pendente.';
  end if;

  update public.deposit_requests
  set status=p_decision,reviewed_at=now()
  where id=v_req.id;

  if p_decision='approved' then
    update public.players
    set balance=balance+v_req.amount,updated_at=now()
    where id=v_req.player_id;

    insert into public.transactions(player_id,kind,amount,status,reference_id,note)
    values(v_req.player_id,'deposit',v_req.amount,'completed',v_req.id,
           'Depósito aprovado · deve ser jogado antes de saque');

    insert into public.deposit_wager_requirements(
      deposit_request_id,player_id,original_amount,remaining_amount,status
    ) values (
      v_req.id,v_req.player_id,v_req.amount,v_req.amount,'active'
    );
  end if;

  return jsonb_build_object(
    'ok',true,
    'status',p_decision,
    'request_id',v_req.id,
    'wager_required',case when p_decision='approved' then v_req.amount else 0 end
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_review_withdrawal(p_token text, p_request_id uuid, p_decision text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_req public.withdrawal_requests%rowtype;
  v_player public.players%rowtype;
  v_locked numeric:=0;
  v_available_before_reservation numeric:=0;
  v_effective_decision text:=p_decision;
  v_reason text;
begin
  perform public.jl_require_admin_elevated(p_token);

  if p_decision not in ('approved','rejected') then
    raise exception 'Decisão inválida.';
  end if;

  select * into v_req
  from public.withdrawal_requests
  where id=p_request_id
  for update;

  if v_req.id is null or v_req.status<>'pending' then
    raise exception 'Pedido de saque não está pendente.';
  end if;

  select * into v_player
  from public.players
  where id=v_req.player_id
  for update;

  v_locked:=public.jl_deposit_wager_locked(v_req.player_id);
  v_available_before_reservation:=greatest(
    0,
    (v_player.balance+v_req.amount)-v_locked
  );

  if p_decision='approved' and v_req.amount>v_available_before_reservation then
    v_effective_decision:='rejected';
    v_reason:='Rejeitado: existe depósito ainda não jogado.';
  elsif p_decision='rejected' then
    v_reason:='Rejeitado pelo administrador';
  end if;

  update public.withdrawal_requests
  set status=v_effective_decision,
      reviewed_at=now(),
      reason=case
        when v_effective_decision='rejected' then v_reason
        else reason
      end
  where id=v_req.id;

  update public.transactions
  set status=case when v_effective_decision='approved' then 'completed' else 'rejected' end
  where reference_id=v_req.id
    and kind='withdrawal'
    and status='pending';

  if v_effective_decision='rejected' then
    update public.players
    set balance=balance+v_req.amount,updated_at=now()
    where id=v_req.player_id;

    insert into public.transactions(
      player_id,kind,amount,status,reference_id,note
    ) values(
      v_req.player_id,'withdrawal_refund',v_req.amount,'completed',v_req.id,
      case
        when p_decision='approved' then
          'Saque bloqueado: depósito ainda precisa ser jogado'
        else
          'Saque rejeitado: valor devolvido ao saldo'
      end
    );
  end if;

  return jsonb_build_object(
    'ok',true,
    'status',v_effective_decision,
    'requested_decision',p_decision,
    'request_id',v_req.id,
    'deposit_locked',v_locked,
    'available_before_reservation',v_available_before_reservation,
    'message',
      case
        when p_decision='approved' and v_effective_decision='rejected'
          then 'Saque não aprovado: o jogador ainda tem depósito por jogar.'
        when v_effective_decision='approved'
          then 'Saque aprovado.'
        else 'Saque rejeitado.'
      end
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_schedule_draws(p_token text, p_start_at timestamp with time zone, p_end_at timestamp with time zone, p_interval_minutes integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return public.jl_admin_schedule_game_draws(
    p_token,'number',p_start_at,p_end_at,p_interval_minutes
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_schedule_game_draws(p_token text, p_game_type text, p_start_at timestamp with time zone, p_end_at timestamp with time zone, p_interval_minutes integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_inserted integer := 0;
  v_requested integer := 0;
begin
  perform public.jl_require_admin(p_token);
  if p_game_type not in ('number','pair') then raise exception 'Jogo inválido.'; end if;
  if p_start_at is null or p_end_at is null then raise exception 'Informe início e fim da programação.'; end if;
  if p_interval_minutes is null or p_interval_minutes < 1 or p_interval_minutes > 1440 then
    raise exception 'O intervalo deve ficar entre 1 e 1440 minutos.';
  end if;
  if p_start_at <= now()+interval '10 seconds' then raise exception 'O primeiro sorteio deve ficar no futuro.'; end if;
  if p_end_at < p_start_at then raise exception 'O fim deve ser igual ou posterior ao início.'; end if;
  if p_end_at > now()+interval '7 days' then raise exception 'A programação pode cobrir no máximo 7 dias.'; end if;

  select count(*) into v_requested
  from generate_series(p_start_at,p_end_at,make_interval(mins=>p_interval_minutes));
  if v_requested > 250 then raise exception 'A programação ultrapassa 250 sorteios por lote.'; end if;

  insert into public.draw_schedule(game_type,draw_at)
  select p_game_type,gs
  from generate_series(p_start_at,p_end_at,make_interval(mins=>p_interval_minutes)) gs
  on conflict (game_type,draw_at) do nothing;
  get diagnostics v_inserted=row_count;

  perform public.jl_process_game(p_game_type);

  return jsonb_build_object(
    'ok',true,'game_type',p_game_type,'requested',v_requested,'inserted',v_inserted,
    'message',v_inserted||' horário(s) programado(s).'
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_session_info(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
begin
  select s.expires_at,s.elevated_until,a.id,a.display_name,a.role
  into r
  from public.admin_sessions s
  join public.admin_accounts a on a.id=s.admin_id and a.active
  where s.token_hash=public.jl_token_hash(p_token)
    and s.expires_at>now()
  limit 1;

  if r.id is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  return jsonb_build_object(
    'id',r.id,
    'name',r.display_name,
    'role',r.role,
    'expires_at',r.expires_at,
    'elevated_until',r.elevated_until,
    'elevated',coalesce(r.elevated_until>now(),false)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_set_account_active(p_token text, p_admin_id uuid, p_active boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me uuid:=public.jl_admin_account_id(p_token);
  v_target public.admin_accounts%rowtype;
begin
  perform public.jl_require_super_admin(p_token);
  perform public.jl_require_admin_elevated(p_token);

  select * into v_target
  from public.admin_accounts
  where id=p_admin_id
  for update;

  if v_target.id is null then
    raise exception 'Administrador não encontrado.';
  end if;
  if v_target.id=v_me and not p_active then
    raise exception 'Não pode desativar a própria conta administrativa.';
  end if;
  if v_target.role='super_admin' and not p_active and not exists(
    select 1 from public.admin_accounts
    where active and role='super_admin' and id<>v_target.id
  ) then
    raise exception 'Não pode desativar o último super administrador.';
  end if;

  update public.admin_accounts
  set active=p_active,updated_at=now()
  where id=v_target.id;

  if not p_active then
    delete from public.admin_sessions where admin_id=v_target.id;
  end if;

  return jsonb_build_object('ok',true,'id',v_target.id,'active',p_active);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_set_blocked(p_token text, p_player_id uuid, p_blocked boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform public.jl_require_admin_elevated(p_token);
  update public.players set blocked=p_blocked,updated_at=now() where id=p_player_id;
  if not found then raise exception 'Jogador não encontrado.'; end if;
  return jsonb_build_object('ok',true,'blocked',p_blocked);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_set_influencer_active(p_token text, p_influencer_id uuid, p_active boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_name text;
begin
  perform public.jl_require_admin(p_token);

  update public.influencers
  set active = coalesce(p_active,false),
      updated_at = now()
  where id = p_influencer_id
  returning name into v_name;

  if v_name is null then
    raise exception 'Influenciador não encontrado.';
  end if;

  return jsonb_build_object(
    'message', case when p_active then 'Influenciador ativado.' else 'Influenciador desativado.' end,
    'active',p_active
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_support_reply(p_token text, p_player_id uuid, p_message text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare msg text:=trim(coalesce(p_message,'')); mid uuid;
begin
  perform public.jl_require_admin(p_token);

  if not exists(select 1 from public.players where id=p_player_id) then
    raise exception 'Jogador não encontrado.';
  end if;

  if char_length(msg)<1 or char_length(msg)>1000 then
    raise exception 'A mensagem deve ter entre 1 e 1000 caracteres.';
  end if;

  insert into public.customer_support_messages(
    player_id,sender,message,read_by_admin,read_by_player
  ) values (
    p_player_id,'admin',msg,true,false
  ) returning id into mid;

  return jsonb_build_object('ok',true,'id',mid,'message','Resposta enviada ao jogador.');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_support_thread(p_token text, p_player_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare msgs jsonb; pname text; pphone text;
begin
  perform public.jl_require_admin(p_token);

  select name,phone into pname,pphone from public.players where id=p_player_id;
  if pname is null then raise exception 'Jogador não encontrado.'; end if;

  update public.customer_support_messages
  set read_by_admin=true
  where player_id=p_player_id and sender='player' and not read_by_admin;

  select coalesce(jsonb_agg(x order by x.created_at),'[]'::jsonb)
  into msgs
  from (
    select id,sender,message,created_at
    from public.customer_support_messages
    where player_id=p_player_id
    order by created_at desc
    limit 150
  ) x;

  return jsonb_build_object(
    'player',jsonb_build_object('id',p_player_id,'name',pname,'phone',pphone),
    'messages',msgs
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_support_threads(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare rows jsonb;
begin
  perform public.jl_require_admin(p_token);

  select coalesce(jsonb_agg(x order by x.last_message_at desc),'[]'::jsonb)
  into rows
  from (
    select
      p.id as player_id,
      p.name,
      p.phone,
      max(m.created_at) as last_message_at,
      count(*) filter(where m.sender='player' and not m.read_by_admin) as unread_count,
      (array_agg(m.message order by m.created_at desc))[1] as last_message,
      (array_agg(m.sender order by m.created_at desc))[1] as last_sender
    from public.customer_support_messages m
    join public.players p on p.id=m.player_id
    group by p.id,p.name,p.phone
  ) x;

  return rows;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_update_game_settings(p_token text, p_game_type text, p_min_bet numeric, p_max_bet numeric, p_multiplier numeric, p_lock_seconds integer, p_draw_mode text, p_enabled boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform public.jl_require_admin(p_token);
  if p_game_type not in ('number','pair') then raise exception 'Jogo inválido.'; end if;

  if exists(
    select 1 from public.game_rounds
    where game_type=p_game_type and status in ('open','locked','closed')
  ) then
    raise exception 'Altere as regras somente quando este jogo não tiver uma rodada ativa.';
  end if;

  if p_min_bet is null or p_min_bet <= 0 or p_max_bet is null or p_max_bet < p_min_bet then
    raise exception 'Limites de aposta inválidos.';
  end if;
  if p_multiplier is null or p_multiplier <= 1 then raise exception 'Multiplicador inválido.'; end if;
  if p_lock_seconds is null or p_lock_seconds < 1 or p_lock_seconds > 60 then raise exception 'Bloqueio deve ficar entre 1 e 60 segundos.'; end if;
  if p_draw_mode not in ('house_min','house_safe_random') then raise exception 'Modo de sorteio inválido.'; end if;

  update public.game_settings
  set min_bet=p_min_bet,max_bet=p_max_bet,multiplier=p_multiplier,
      lock_seconds=p_lock_seconds,draw_mode=p_draw_mode,
      enabled=coalesce(p_enabled,true),updated_at=now()
  where game_type=p_game_type;

  return jsonb_build_object('ok',true,'game_type',p_game_type,'message','Configuração atualizada.');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_update_player_name(p_token text, p_player_id uuid, p_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_old_name text;
  v_new_name text := regexp_replace(trim(coalesce(p_name, '')), '[[:space:]]+', ' ', 'g');
begin
  perform public.jl_require_admin(p_token);

  if char_length(v_new_name) < 2 or char_length(v_new_name) > 60 then
    raise exception 'O nome deve ter entre 2 e 60 caracteres.';
  end if;

  select name into v_old_name
  from public.players
  where id = p_player_id
    and deleted_at is null
  for update;

  if v_old_name is null then
    raise exception 'Jogador não encontrado.';
  end if;

  update public.players
  set name = v_new_name,
      updated_at = now()
  where id = p_player_id
    and deleted_at is null;

  insert into public.audit_log(action, details)
  values(
    'admin_update_player_name',
    jsonb_build_object(
      'player_id', p_player_id,
      'old_name', v_old_name,
      'new_name', v_new_name,
      'at', now()
    )
  );

  return jsonb_build_object(
    'ok', true,
    'player_id', p_player_id,
    'name', v_new_name,
    'message', 'Nome do jogador atualizado.'
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_verify_account_code(p_admin_id uuid, p_code text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  a public.admin_accounts%rowtype;
  v_sha text;
  v_new_hash text;
begin
  select * into a
  from public.admin_accounts
  where id=p_admin_id
  for update;

  if a.id is null or not a.active or a.code_hash is null then
    return false;
  end if;

  if a.code_scheme='bcrypt'
     and extensions.crypt(coalesce(p_code,''),a.code_hash)=a.code_hash then
    return true;
  end if;

  if a.code_scheme='bcrypt_sha256' then
    v_sha:=encode(extensions.digest(coalesce(p_code,''),'sha256'),'hex');
    if extensions.crypt(v_sha,a.code_hash)=a.code_hash then
      v_new_hash:=extensions.crypt(coalesce(p_code,''),extensions.gen_salt('bf',12));

      update public.admin_accounts
      set code_hash=v_new_hash,
          code_scheme='bcrypt',
          updated_at=now()
      where id=a.id;

      if a.is_primary then
        update public.admin_config
        set code_hash=v_new_hash,
            updated_at=now();
      end if;

      return true;
    end if;
  end if;

  return false;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_admin_verify_code_for_token(p_token text, p_code text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_admin uuid:=public.jl_admin_account_id(p_token);
begin
  if v_admin is null then
    return false;
  end if;
  return public.jl_admin_verify_account_code(v_admin,p_code);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_apply_cash_wager(p_player_id uuid, p_amount numeric, p_source_type text, p_reference_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r public.deposit_wager_requirements%rowtype;
  need numeric:=greatest(0,coalesce(p_amount,0));
  take numeric;
  cleared numeric:=0;
begin
  if p_source_type not in ('number_bet','pair_bet','ludo_stake','ludo_reentry') then
    raise exception 'Origem de jogo inválida.';
  end if;
  if need<=0 then return 0; end if;

  for r in
    select *
    from public.deposit_wager_requirements
    where player_id=p_player_id
      and status='active'
      and remaining_amount>0
    order by created_at,id
    for update
  loop
    exit when need<=0;
    take:=least(need,r.remaining_amount);

    update public.deposit_wager_requirements
    set remaining_amount=remaining_amount-take,
        status=case when remaining_amount-take<=0 then 'cleared' else 'active' end,
        updated_at=now()
    where id=r.id;

    insert into public.deposit_wager_usages(
      requirement_id,player_id,source_type,reference_id,amount
    ) values (
      r.id,p_player_id,p_source_type,p_reference_id,take
    );

    cleared:=cleared+take;
    need:=need-take;
  end loop;

  return cleared;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_assign_daily_round_no()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  new.round_day := (new.draw_at at time zone 'Africa/Maputo')::date;

  if new.round_no is null then
    perform pg_advisory_xact_lock(
      hashtextextended(
        'jl_daily_round:'||new.game_type||':'||new.round_day::text,
        0
      )
    );

    select coalesce(max(g.round_no),0)+1
    into new.round_no
    from public.game_rounds g
    where g.game_type=new.game_type
      and g.round_day=new.round_day;
  end if;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_audit_admin_row_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_admin text:=nullif(current_setting('jl.admin_id',true),'');
  v_session text:=nullif(current_setting('jl.admin_session_id',true),'');
  v_name text:=nullif(current_setting('jl.admin_name',true),'');
  v_role text:=nullif(current_setting('jl.admin_role',true),'');
  v_before jsonb;
  v_after jsonb;
  v_action text;
  v_target_id text;
begin
  if v_admin is null then
    return case when tg_op='DELETE' then old else new end;
  end if;

  v_before:=case when tg_op='INSERT' then null else to_jsonb(old) end;
  v_after:=case when tg_op='DELETE' then null else to_jsonb(new) end;

  if v_before is not null then
    v_before:=v_before - array['pin_hash','secret_hash','otp_hash','code_hash','legacy_sha256_hash','token_hash'];
  end if;
  if v_after is not null then
    v_after:=v_after - array['pin_hash','secret_hash','otp_hash','code_hash','legacy_sha256_hash','token_hash'];
  end if;

  v_target_id:=coalesce(v_after->>'id',v_before->>'id');

  if tg_table_name='players' then
    if tg_op='UPDATE' and old.blocked is distinct from new.blocked then
      v_action:='admin_set_blocked';
    elsif tg_op='UPDATE' and old.balance is distinct from new.balance then
      v_action:='admin_player_balance_change';
    else
      return new;
    end if;
  elsif tg_table_name='deposit_requests' then
    v_action:='admin_review_deposit';
  elsif tg_table_name='withdrawal_requests' then
    v_action:='admin_review_withdrawal';
  elsif tg_table_name='game_settings' then
    v_action:='admin_update_game_settings';
    v_target_id:=coalesce(v_after->>'game_type',v_before->>'game_type');
  elsif tg_table_name='influencers' then
    if tg_op='INSERT' then v_action:='admin_create_influencer';
    elsif old.active is distinct from new.active then v_action:='admin_set_influencer_active';
    else v_action:='admin_update_influencer';
    end if;
  elsif tg_table_name='draw_schedule' then
    if tg_op='INSERT' then v_action:='admin_add_draw_time';
    elsif new.status='cancelled' and old.status is distinct from new.status then v_action:='admin_cancel_draw_time';
    else v_action:='admin_update_draw_schedule';
    end if;
  elsif tg_table_name='game_rounds' then
    if tg_op='INSERT' then v_action:='admin_open_game_round';
    else v_action:='admin_update_game_round';
    end if;
  elsif tg_table_name='pin_recovery_requests' then
    v_action:='admin_pin_recovery_change';
  elsif tg_table_name='admin_accounts' then
    if tg_op='INSERT' then v_action:='admin_create_account';
    elsif old.active is distinct from new.active then v_action:='admin_set_account_active';
    elsif old.role is distinct from new.role or old.display_name is distinct from new.display_name then v_action:='admin_update_account';
    elsif old.code_scheme is distinct from new.code_scheme or old.code_hash is distinct from new.code_hash then v_action:='admin_change_admin_code';
    else return new;
    end if;
  else
    v_action:='admin_'||lower(tg_op)||'_'||tg_table_name;
  end if;

  insert into public.audit_log(
    action,details,actor_admin_id,actor_session_id,actor_name,actor_role,
    target_type,target_id,before_state,after_state
  ) values(
    v_action,
    jsonb_build_object(
      'operation',tg_op,
      'table',tg_table_name,
      'target_id',v_target_id,
      'at',now()
    ),
    v_admin::uuid,
    case when v_session is null then null else v_session::uuid end,
    v_name,
    v_role,
    tg_table_name,
    v_target_id,
    v_before,
    v_after
  );

  return case when tg_op='DELETE' then old else new end;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_bonus_available(p_player_id uuid, p_game_type text)
 RETURNS numeric
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(sum(remaining_amount),0)
  from public.bonus_grants
  where player_id=p_player_id
    and status='active'
    and remaining_amount>0
    and (game_scope=p_game_type or game_scope='both');
$function$
;

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
$function$
;

CREATE OR REPLACE FUNCTION public.jl_confirm_pin_recovery(p_phone text, p_email text, p_code text, p_new_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_phone text:=public.jl_phone(p_phone);
  r public.pin_recovery_requests%rowtype;
  v_attempts integer;
begin
  if coalesce(p_code,'') !~ '^[0-9]{6}$'
     or coalesce(p_new_pin,'') !~ '^[0-9]{4,8}$' then
    return jsonb_build_object('ok',false,'error','Código inválido ou expirado.');
  end if;

  -- O e-mail é apenas um canal opcional de contacto. A confirmação usa telefone + código.
  select pr.* into r
  from public.pin_recovery_requests pr
  join public.players p on p.id=pr.player_id and p.deleted_at is null
  where pr.phone=v_phone
    and pr.status='code_sent'
  order by pr.sent_at desc nulls last, pr.requested_at desc
  limit 1
  for update of pr;

  if r.id is null then
    return jsonb_build_object('ok',false,'error','Código inválido ou expirado.');
  end if;

  if r.otp_expires_at is null or r.otp_expires_at<=now() then
    update public.pin_recovery_requests
    set status='expired',otp_hash=null,otp_expires_at=null,updated_at=now()
    where id=r.id;
    return jsonb_build_object('ok',false,'error','Código inválido ou expirado.');
  end if;

  if r.otp_attempts>=5 then
    update public.pin_recovery_requests
    set status='expired',otp_hash=null,otp_expires_at=null,updated_at=now()
    where id=r.id;
    return jsonb_build_object('ok',false,'error','Código bloqueado. Faça um novo pedido de recuperação.');
  end if;

  if r.otp_hash is null or extensions.crypt(p_code,r.otp_hash)<>r.otp_hash then
    v_attempts:=r.otp_attempts+1;
    update public.pin_recovery_requests
    set otp_attempts=v_attempts,
        status=case when v_attempts>=5 then 'expired' else status end,
        otp_hash=case when v_attempts>=5 then null else otp_hash end,
        otp_expires_at=case when v_attempts>=5 then null else otp_expires_at end,
        updated_at=now()
    where id=r.id;

    return jsonb_build_object(
      'ok',false,
      'error',case when v_attempts>=5
        then 'Código bloqueado. Faça um novo pedido de recuperação.'
        else 'Código inválido ou expirado.'
      end,
      'attempts_remaining',greatest(0,5-v_attempts)
    );
  end if;

  update public.players
  set pin_hash=extensions.crypt(p_new_pin,extensions.gen_salt('bf',10)),
      updated_at=now()
  where id=r.player_id and deleted_at is null;

  if not found then
    update public.pin_recovery_requests
    set status='cancelled',otp_hash=null,otp_expires_at=null,updated_at=now()
    where id=r.id;
    return jsonb_build_object('ok',false,'error','Conta indisponível.');
  end if;

  delete from public.player_sessions where player_id=r.player_id;

  update public.pin_recovery_requests
  set status='completed',
      completed_at=now(),
      updated_at=now(),
      otp_hash=null,
      otp_expires_at=null
  where id=r.id;

  return jsonb_build_object(
    'ok',true,
    'message','PIN alterado com sucesso. Entre novamente com o novo PIN.'
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_consume_bonus(p_player_id uuid, p_game_type text, p_amount numeric, p_bet_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  g public.bonus_grants%rowtype;
  need numeric:=greatest(0,coalesce(p_amount,0));
  take numeric;
  used numeric:=0;
begin
  if p_game_type not in ('number','pair') then raise exception 'Jogo de bónus inválido.'; end if;
  if need<=0 then return 0; end if;

  for g in
    select *
    from public.bonus_grants
    where player_id=p_player_id
      and status='active'
      and remaining_amount>0
      and (game_scope=p_game_type or game_scope='both')
    order by created_at,id
    for update
  loop
    exit when need<=0;
    take:=least(need,g.remaining_amount);

    update public.bonus_grants
    set remaining_amount=remaining_amount-take,
        played_amount=played_amount+take,
        status=case when remaining_amount-take<=0 then 'consumed' else 'active' end,
        updated_at=now()
    where id=g.id;

    insert into public.bonus_usages(grant_id,player_id,game_type,bet_id,amount)
    values(g.id,p_player_id,p_game_type,p_bet_id,take);

    used:=used+take;
    need:=need-take;
  end loop;

  return used;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_cron_prune_history()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cron', 'public'
AS $function$
declare
  v_deleted integer:=0;
begin
  delete from cron.job_run_details
  where
    (status='succeeded' and coalesce(end_time,start_time)<now()-interval '48 hours')
    or
    (coalesce(status,'')<>'succeeded' and start_time<now()-interval '30 days');

  get diagnostics v_deleted=row_count;
  return v_deleted;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_deposit_wager_locked(p_player_id uuid)
 RETURNS numeric
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(sum(remaining_amount),0)
  from public.deposit_wager_requirements
  where player_id=p_player_id
    and status='active'
    and remaining_amount>0;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_enrich_admin_audit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_admin text:=nullif(current_setting('jl.admin_id',true),'');
  v_session text:=nullif(current_setting('jl.admin_session_id',true),'');
  v_name text:=nullif(current_setting('jl.admin_name',true),'');
  v_role text:=nullif(current_setting('jl.admin_role',true),'');
begin
  if new.actor_admin_id is null and v_admin is not null then
    new.actor_admin_id:=v_admin::uuid;
  end if;
  if new.actor_session_id is null and v_session is not null then
    new.actor_session_id:=v_session::uuid;
  end if;
  new.actor_name:=coalesce(new.actor_name,v_name);
  new.actor_role:=coalesce(new.actor_role,v_role);

  if v_admin is not null then
    new.details:=coalesce(new.details,'{}'::jsonb)
      || jsonb_build_object(
        'admin_id',v_admin,
        'admin_session_id',v_session,
        'admin_name',v_name,
        'admin_role',v_role
      );
  end if;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_finalize_due_rounds()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return public.jl_finalize_game_due_rounds('number');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_finalize_game_due_rounds(p_game_type text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_round public.game_rounds%rowtype;
  v_settings public.game_settings%rowtype;
  v_number integer;
  v_pair integer[];
  v_count integer := 0;
begin
  select * into v_settings from public.game_settings where game_type=p_game_type;
  if v_settings.game_type is null then raise exception 'Jogo inválido.'; end if;

  for v_round in
    select *
    from public.game_rounds
    where game_type=p_game_type
      and status in ('open','locked','closed')
      and draw_at <= now()
    order by draw_at,opened_at
    for update skip locked
  loop
    if p_game_type='number' then
      v_number := public.jl_secure_number(v_round.id);

      update public.game_rounds
      set status='published',
          closed_at=coalesce(closed_at,closes_at),
          drawn_number=v_number,
          drawn_at=now(),published_at=now()
      where id=v_round.id;

      update public.bets
      set won=(selected_number=v_number),
          payout=case when selected_number=v_number then round(amount*v_settings.multiplier,2) else 0 end
      where round_id=v_round.id;

      update public.players p
      set balance=p.balance+w.total,updated_at=now()
      from (
        select player_id,sum(payout) total
        from public.bets
        where round_id=v_round.id and won=true and payout>0
        group by player_id
      ) w
      where p.id=w.player_id;

      insert into public.transactions(player_id,kind,amount,status,reference_id,note)
      select player_id,'payout',payout,'completed',id,
             'Prêmio Número Lendário da rodada '||v_round.round_no
      from public.bets
      where round_id=v_round.id and won=true and payout>0;

      insert into public.audit_log(action,details)
      values('number.round_published',jsonb_build_object(
        'round_id',v_round.id,'round_no',v_round.round_no,
        'drawn_number',v_number,'draw_mode',v_settings.draw_mode,
        'multiplier',v_settings.multiplier,'processed_at',now()
      ));
    else
      v_pair := public.jl_secure_pair(v_round.id);

      update public.game_rounds
      set status='published',
          closed_at=coalesce(closed_at,closes_at),
          pair_drawn_a=v_pair[1],pair_drawn_b=v_pair[2],
          drawn_at=now(),published_at=now()
      where id=v_round.id;

      update public.pair_bets
      set won=(number_a=v_pair[1] and number_b=v_pair[2]),
          payout=case when number_a=v_pair[1] and number_b=v_pair[2]
                      then round(amount*v_settings.multiplier,2) else 0 end
      where round_id=v_round.id;

      update public.players p
      set balance=p.balance+w.total,updated_at=now()
      from (
        select player_id,sum(payout) total
        from public.pair_bets
        where round_id=v_round.id and won=true and payout>0
        group by player_id
      ) w
      where p.id=w.player_id;

      insert into public.transactions(player_id,kind,amount,status,reference_id,note)
      select player_id,'payout',payout,'completed',id,
             'Prêmio Dupla Lendária '||v_pair[1]||'+'||v_pair[2]||' da rodada '||v_round.round_no
      from public.pair_bets
      where round_id=v_round.id and won=true and payout>0;

      insert into public.audit_log(action,details)
      values('pair.round_published',jsonb_build_object(
        'round_id',v_round.id,'round_no',v_round.round_no,
        'pair_drawn_a',v_pair[1],'pair_drawn_b',v_pair[2],
        'draw_mode',v_settings.draw_mode,'multiplier',v_settings.multiplier,
        'processed_at',now()
      ));
    end if;

    if v_round.schedule_id is not null then
      update public.draw_schedule
      set status='completed',updated_at=now()
      where id=v_round.schedule_id;
    end if;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_financial_idempotency_claim(p_subject_type text, p_subject_id uuid, p_operation text, p_request_key text, p_request_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_inserted boolean:=false;
  v_hash text;
  v_response jsonb;
begin
  if p_subject_type not in ('player','admin') then
    raise exception 'Tipo de operação financeira inválido.';
  end if;
  if p_subject_id is null then
    raise exception 'Identidade financeira inválida.';
  end if;
  if char_length(coalesce(p_request_key,''))<16 or char_length(p_request_key)>120 then
    raise exception 'Chave de idempotência inválida.';
  end if;

  insert into public.financial_idempotency(
    subject_type,subject_id,operation,request_key,request_hash
  ) values(
    p_subject_type,p_subject_id,p_operation,p_request_key,p_request_hash
  )
  on conflict do nothing
  returning true into v_inserted;

  if coalesce(v_inserted,false) then
    return jsonb_build_object('claimed',true);
  end if;

  select request_hash,response
  into v_hash,v_response
  from public.financial_idempotency
  where subject_type=p_subject_type
    and subject_id=p_subject_id
    and operation=p_operation
    and request_key=p_request_key;

  if v_hash is distinct from p_request_hash then
    raise exception 'A mesma chave de operação não pode ser reutilizada com dados diferentes.';
  end if;

  if v_response is null then
    raise exception 'Operação financeira ainda em processamento. Tente novamente.';
  end if;

  return jsonb_build_object('claimed',false,'response',v_response);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_financial_idempotency_complete(p_subject_type text, p_subject_id uuid, p_operation text, p_request_key text, p_response jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update public.financial_idempotency
  set response=p_response,completed_at=now()
  where subject_type=p_subject_type
    and subject_id=p_subject_id
    and operation=p_operation
    and request_key=p_request_key;
  if not found then raise exception 'Registo de idempotência financeira não encontrado.'; end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_game_public_state(p_game_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_round public.game_rounds%rowtype;
  v_last public.game_rounds%rowtype;
  v_settings public.game_settings%rowtype;
begin
  select * into v_settings from public.game_settings where game_type=p_game_type;

  select * into v_round
  from public.game_rounds
  where game_type=p_game_type and status in ('open','locked','closed')
  order by opened_at desc limit 1;

  select * into v_last
  from public.game_rounds
  where game_type=p_game_type and status='published'
  order by published_at desc nulls last,opened_at desc limit 1;

  return jsonb_build_object(
    'game_type',p_game_type,
    'settings',jsonb_build_object(
      'min_bet',v_settings.min_bet,'max_bet',v_settings.max_bet,
      'multiplier',v_settings.multiplier,'lock_seconds',v_settings.lock_seconds,
      'draw_mode',v_settings.draw_mode,'enabled',v_settings.enabled
    ),
    'current_round',case when v_round.id is null then null else jsonb_build_object(
      'id',v_round.id,'round_no',v_round.round_no,'status',v_round.status,
      'opened_at',v_round.opened_at,'closes_at',v_round.closes_at,'draw_at',v_round.draw_at
    ) end,
    'last_result',case when v_last.id is null then null else jsonb_build_object(
      'round_no',v_last.round_no,'drawn_number',v_last.drawn_number,
      'pair_drawn_a',v_last.pair_drawn_a,'pair_drawn_b',v_last.pair_drawn_b,
      'drawn_at',v_last.drawn_at,'published_at',v_last.published_at
    ) end
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_guard_ludo_queue_funds()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform public.jl_require_cash_balance(new.player_id,new.bet_amount);
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_guard_ludo_reentry_wager()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.kind='ludo_reentry'
     and new.amount<0
     and new.reference_id is not null
     and not exists(
       select 1 from public.deposit_wager_usages u
       where u.player_id=new.player_id
         and u.source_type='ludo_reentry'
         and u.reference_id=new.reference_id
     ) then
    perform public.jl_apply_cash_wager(
      new.player_id,
      abs(new.amount),
      'ludo_reentry',
      new.reference_id
    );
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_guard_ludo_room_member_funds()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_bet numeric;
  v_status text;
begin
  select bet_amount,status into v_bet,v_status
  from public.ludo_rooms
  where id=new.room_id;

  if v_status in ('waiting','negotiating') and coalesce(new.status,'active')<>'left' then
    perform public.jl_require_cash_balance(new.player_id,v_bet);
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_login_player(p_phone text, p_pin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_phone text := public.jl_phone(p_phone);
  v_player public.players%rowtype;
  v_token text;
  v_headers jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  v_ip text;
  v_agent text;
  v_source text;
  v_key text;
  v_rate public.login_rate_limits%rowtype;
  v_failed integer;
  v_level integer;
  v_minutes integer;
  v_retry integer;
begin
  v_ip := nullif(btrim(split_part(coalesce(v_headers->>'x-forwarded-for',''), ',', 1)), '');
  if v_ip is null then v_ip := nullif(v_headers->>'cf-connecting-ip',''); end if;
  if v_ip is null then v_ip := nullif(v_headers->>'x-real-ip',''); end if;
  v_agent := nullif(left(coalesce(v_headers->>'user-agent',''),300),'');
  v_source := coalesce(v_ip,v_agent,'unknown');
  v_key := encode(extensions.digest(v_phone || '|' || v_source,'sha256'),'hex');

  insert into public.login_rate_limits(scope,subject_key)
  values('player',v_key)
  on conflict(scope,subject_key) do nothing;

  select * into v_rate
  from public.login_rate_limits
  where scope='player' and subject_key=v_key
  for update;

  if v_rate.last_failed_at is not null
     and v_rate.last_failed_at<now()-interval '24 hours'
     and coalesce(v_rate.blocked_until,'-infinity'::timestamptz)<=now() then
    update public.login_rate_limits
    set failed_attempts=0,block_level=0,blocked_until=null,updated_at=now()
    where scope='player' and subject_key=v_key;
    v_rate.failed_attempts:=0;
    v_rate.block_level:=0;
    v_rate.blocked_until:=null;
  end if;

  if v_rate.blocked_until is not null and v_rate.blocked_until>now() then
    v_retry:=greatest(1,ceil(extract(epoch from (v_rate.blocked_until-now()))/60.0)::integer);
    perform set_config('response.status','429',true);
    return jsonb_build_object(
      'ok',false,
      'message',format('Muitas tentativas. Tente novamente em %s minuto(s).',v_retry),
      'retry_after_minutes',v_retry
    );
  end if;

  select * into v_player
  from public.players
  where phone=v_phone
  limit 1;

  if v_player.id is null
     or extensions.crypt(coalesce(p_pin,''),v_player.pin_hash)<>v_player.pin_hash then
    v_failed:=coalesce(v_rate.failed_attempts,0)+1;

    if v_failed>=5 then
      v_level:=coalesce(v_rate.block_level,0)+1;
      v_minutes:=case v_level
        when 1 then 5
        when 2 then 15
        when 3 then 30
        when 4 then 60
        when 5 then 120
        when 6 then 240
        when 7 then 480
        when 8 then 960
        else 1440
      end;

      update public.login_rate_limits
      set failed_attempts=0,
          block_level=v_level,
          blocked_until=now()+make_interval(mins=>v_minutes),
          last_failed_at=now(),
          updated_at=now()
      where scope='player' and subject_key=v_key;

      perform set_config('response.status','429',true);
      return jsonb_build_object(
        'ok',false,
        'message',format('Muitas tentativas. Tente novamente em %s minuto(s).',v_minutes),
        'retry_after_minutes',v_minutes
      );
    end if;

    update public.login_rate_limits
    set failed_attempts=v_failed,last_failed_at=now(),updated_at=now()
    where scope='player' and subject_key=v_key;

    perform set_config('response.status','401',true);
    return jsonb_build_object(
      'ok',false,
      'message','Telefone ou PIN incorreto.',
      'attempts_remaining',5-v_failed
    );
  end if;

  if v_player.blocked then
    perform set_config('response.status','403',true);
    return jsonb_build_object('ok',false,'message','Esta conta está bloqueada.');
  end if;

  delete from public.login_rate_limits
  where scope='player' and subject_key=v_key;

  v_token:=encode(extensions.gen_random_bytes(32),'hex');

  insert into public.player_sessions(
    player_id,token_hash,expires_at,last_seen_at,rotated_at,ip_address,user_agent
  ) values(
    v_player.id,
    public.jl_token_hash(v_token),
    now()+interval '30 days',
    now(),
    now(),
    v_ip,
    v_agent
  );

  return jsonb_build_object(
    'ok',true,
    'token',v_token,
    'player',jsonb_build_object(
      'id',v_player.id,
      'name',v_player.name,
      'phone',v_player.phone,
      'balance',v_player.balance,
      'blocked',v_player.blocked
    )
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_logout_player(p_token text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  delete from public.player_sessions where token_hash = public.jl_token_hash(p_token);
  return true;
end;
$function$
;

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
$function$
;

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

  if target.id is null then
    raise exception 'Desafio público não encontrado.';
  end if;

  if not exists(
    select 1
    from public.ludo_room_players host_rp
    where host_rp.room_id=target.id
      and host_rp.player_id=target.host_id
      and host_rp.status<>'left'
  ) or not exists(
    select 1
    from public.player_sessions ps
    where ps.player_id=target.host_id
      and ps.expires_at>now()
      and ps.last_seen_at>=now()-interval '30 seconds'
  ) then
    raise exception 'Desafio público não encontrado.';
  end if;

  select count(*) into joined
  from public.ludo_room_players
  where room_id=target.id and status<>'left';

  if joined>=target.player_count then
    raise exception 'Este desafio já está completo.';
  end if;

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
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_accept_rules(p_token text, p_room uuid, p_accept boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  c int;
  a int;
begin
  select * into r from public.ludo_rooms where id=p_room for update;

  if r.id is null
     or r.status not in ('waiting','negotiating')
     or not public.jl_ludo_is_member(p_room,me) then
    raise exception 'Sala indisponível.';
  end if;

  if not p_accept then
    update public.ludo_room_players
    set accepted_rules_version=null
    where room_id=p_room and player_id=me;

    perform public.jl_ludo_event(
      p_room,me,'rules_declined',
      jsonb_build_object('version',r.rules_version)
    );

    return public.jl_ludo_room_state(p_token,p_room);
  end if;

  update public.ludo_room_players
  set accepted_rules_version=r.rules_version
  where room_id=p_room and player_id=me and status<>'left';

  perform public.jl_ludo_event(
    p_room,me,'rules_accepted',
    jsonb_build_object('version',r.rules_version,'no_deadline',true)
  );

  select count(*),count(*) filter(where accepted_rules_version=r.rules_version)
  into c,a
  from public.ludo_room_players
  where room_id=p_room and status<>'left';

  if c=r.player_count and a=c then
    update public.ludo_rooms
    set status='funding',
        action_deadline=now()+make_interval(secs=>(rules->>'stake_seconds')::int),
        negotiation_grace_used=false,
        updated_at=now()
    where id=p_room;

    perform public.jl_ludo_event(
      p_room,me,'rules_unanimous',
      jsonb_build_object('version',r.rules_version,'accepted_without_deadline',true)
    );
  end if;

  return public.jl_ludo_room_state(p_token,p_room);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_advance_turn(p_room uuid, p_current uuid, p_extra boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r public.ludo_rooms%rowtype;
  curseat int;
  nxt uuid;
  secs int;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.status<>'playing' then return; end if;
  if public.jl_ludo_check_finish(p_room) then return; end if;

  secs:=(r.rules->>'turn_seconds')::int;

  if p_extra and exists(
    select 1 from public.ludo_room_players
    where room_id=p_room and player_id=p_current and status='active'
  ) then
    nxt:=p_current;
  else
    select seat into curseat
    from public.ludo_room_players
    where room_id=p_room and player_id=p_current;

    select player_id into nxt
    from public.ludo_room_players
    where room_id=p_room and status='active' and seat>coalesce(curseat,0)
    order by seat limit 1;

    if nxt is null then
      select player_id into nxt
      from public.ludo_room_players
      where room_id=p_room and status='active'
      order by seat limit 1;
    end if;
  end if;

  if nxt is null then
    perform public.jl_ludo_check_finish(p_room);
    return;
  end if;

  if nxt<>p_current then
    update public.ludo_room_players
    set consecutive_sixes=0
    where room_id=p_room and player_id=p_current;
  end if;

  update public.ludo_rooms
  set current_player_id=nxt,
      turn_phase='roll',
      dice_result=null,
      dice_values='[]'::jsonb,
      dice_position=-1,
      finish_bonus_pending=false,
      action_deadline=now()+make_interval(secs=>secs),
      updated_at=now()
  where id=p_room;

  perform public.jl_ludo_event(
    p_room,nxt,'turn_started',
    jsonb_build_object(
      'deadline',now()+make_interval(secs=>secs),
      'extra_turn',p_extra
    )
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_apply_capture_penalty(p_room uuid, p_player uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_cancel_or_leave(p_token text, p_room uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  rp public.ludo_room_players%rowtype;
  joined_after int;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  select * into rp from public.ludo_room_players where room_id=p_room and player_id=me for update;
  if r.id is null or rp.player_id is null then raise exception 'Sala inválida.'; end if;
  if r.status in ('finished','cancelled') then return jsonb_build_object('ok',true); end if;

  if r.status='playing' then
    raise exception 'A partida está em andamento. Use o botão Desistir se realmente quiser abandonar o jogo.';
  end if;

  if r.host_id=me then
    perform public.jl_ludo_refund_room(p_room,'Reembolso: sala cancelada pelo anfitrião');
    update public.ludo_rooms
    set status='cancelled',action_deadline=null,negotiation_grace_used=false,updated_at=now()
    where id=p_room;
    update public.ludo_room_players set status='left' where room_id=p_room;
    update public.ludo_invitations
    set status='cancelled'
    where room_id=p_room and status in ('pending','accepted');
  else
    if r.status='funding' then
      perform public.jl_ludo_refund_room(p_room,'Reembolso: jogador saiu antes do início');
    elsif rp.stake_paid then
      update public.players
      set balance=balance+rp.stake_amount,updated_at=now()
      where id=me;
      insert into public.transactions(player_id,kind,amount,status,reference_id,note)
      values(me,'ludo_refund',rp.stake_amount,'completed',p_room,'Reembolso: saída antes do início');
      update public.ludo_rooms
      set pot=greatest(0,pot-rp.stake_amount),updated_at=now()
      where id=p_room;
    end if;

    update public.ludo_room_players
    set status='left',stake_paid=false,stake_amount=0
    where room_id=p_room and player_id=me;

    select count(*) into joined_after
    from public.ludo_room_players
    where room_id=p_room and status<>'left';

    if joined_after<r.player_count then
      update public.ludo_rooms
      set status='waiting',action_deadline=null,negotiation_grace_used=false,updated_at=now()
      where id=p_room;
    end if;
  end if;

  return jsonb_build_object('ok',true);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_check_finish(p_room uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r public.ludo_rooms%rowtype;
  p uuid;
  tm int;
  active_players int;
  active_teams int;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.status<>'playing' then return false; end if;

  update public.ludo_room_players rp
  set status='finished'
  where rp.room_id=p_room
    and rp.status='active'
    and 4=(
      select count(*)
      from public.ludo_tokens t
      where t.room_id=p_room
        and t.player_id=rp.player_id
        and t.steps=56
    );

  if r.mode='solo' then
    select player_id into p
    from public.ludo_room_players
    where room_id=p_room and status='finished'
    order by seat limit 1;

    if p is not null then
      perform public.jl_ludo_finish_room(p_room,p,null);
      return true;
    end if;

    select count(*) into active_players
    from public.ludo_room_players
    where room_id=p_room and status in ('active','reentry');

    if active_players=1 then
      select player_id into p
      from public.ludo_room_players
      where room_id=p_room and status in ('active','reentry')
      limit 1;
      perform public.jl_ludo_finish_room(p_room,p,null);
      return true;
    end if;
  else
    select team into tm
    from public.ludo_room_players
    where room_id=p_room
    group by team
    having bool_and(status='finished') and count(*)=2
    limit 1;

    if tm is not null then
      perform public.jl_ludo_finish_room(p_room,null,tm);
      return true;
    end if;

    select count(distinct team) into active_teams
    from public.ludo_room_players
    where room_id=p_room and status in ('active','reentry','finished');

    if active_teams=1 then
      select team into tm
      from public.ludo_room_players
      where room_id=p_room and status in ('active','reentry','finished')
      limit 1;
      perform public.jl_ludo_finish_room(p_room,null,tm);
      return true;
    end if;
  end if;

  return false;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_color_start(p_color text)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$ select case p_color when 'red' then 0 when 'green' then 13 when 'yellow' then 26 when 'blue' then 39 else null end; $function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_commit_stake(p_token text, p_room uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  pl public.players%rowtype;
  rp public.ludo_room_players%rowtype;
  cleared numeric:=0;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.id is null or r.status<>'funding' then raise exception 'A sala ainda não está na fase de aposta.'; end if;
  if r.action_deadline<=now() then raise exception 'Tempo para confirmar a aposta expirou.'; end if;

  select * into rp
  from public.ludo_room_players
  where room_id=p_room and player_id=me and status<>'left'
  for update;

  if rp.player_id is null or rp.accepted_rules_version<>r.rules_version then
    raise exception 'Aceite primeiro as regras atuais.';
  end if;

  if rp.stake_paid then return public.jl_ludo_room_state(p_token,p_room); end if;

  select * into pl from public.players where id=me for update;
  if pl.blocked then raise exception 'Conta bloqueada.'; end if;
  if pl.balance<r.bet_amount then raise exception 'Saldo insuficiente para a aposta desta sala.'; end if;

  update public.players set balance=balance-r.bet_amount,updated_at=now() where id=me;
  cleared:=public.jl_apply_cash_wager(me,r.bet_amount,'ludo_stake',p_room);

  update public.ludo_room_players
  set stake_paid=true,stake_amount=r.bet_amount
  where room_id=p_room and player_id=me;

  update public.ludo_rooms
  set pot=pot+r.bet_amount,updated_at=now()
  where id=p_room;

  insert into public.transactions(player_id,kind,amount,status,reference_id,note)
  values(me,'ludo_stake',-r.bet_amount,'completed',p_room,
         'Aposta Ludo '||r.code||' · '||cleared||' MZN de depósito liberado');

  perform public.jl_ludo_event(
    p_room,me,'stake_committed',
    jsonb_build_object('amount',r.bet_amount,'deposit_wager_cleared',cleared)
  );

  if not exists(
    select 1
    from public.ludo_room_players
    where room_id=p_room and status<>'left' and not stake_paid
  ) then
    perform public.jl_ludo_start_game(p_room);
  end if;

  return public.jl_ludo_room_state(p_token,p_room);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_continue_multi_dice(p_room uuid, p_player uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r public.ludo_rooms%rowtype;
  idx integer;
  total integer;
  d integer;
  moves jsonb;
  move_secs integer;
  bonus boolean:=false;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.status<>'playing' or r.current_player_id<>p_player then return false; end if;

  total := jsonb_array_length(coalesce(r.dice_values,'[]'::jsonb));
  idx := coalesce(r.dice_position,-1) + 1;
  move_secs := (r.rules->>'move_seconds')::int;

  while idx < total loop
    d := (r.dice_values->>idx)::integer;
    moves := public.jl_ludo_legal_moves_data(p_room,p_player,d);

    if jsonb_array_length(moves) > 0 then
      update public.ludo_rooms
      set dice_position=idx,
          dice_result=d,
          turn_phase='move',
          action_deadline=now()+make_interval(secs=>move_secs),
          updated_at=now()
      where id=p_room;

      perform public.jl_ludo_event(
        p_room,p_player,'multi_die_ready',
        jsonb_build_object('position',idx,'dice',d,'total',total)
      );
      return true;
    end if;

    perform public.jl_ludo_event(
      p_room,p_player,'multi_die_skipped',
      jsonb_build_object('position',idx,'dice',d,'reason','no_legal_move')
    );

    idx := idx + 1;
  end loop;

  select coalesce(finish_bonus_pending,false)
  into bonus
  from public.ludo_rooms
  where id=p_room;

  perform public.jl_ludo_advance_turn(p_room,p_player,bonus);
  return false;
end;
$function$
;

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
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_data_retention_maintenance(p_hot_days integer DEFAULT 90, p_batch_limit integer DEFAULT 5000)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cutoff timestamptz;
  v_inserted integer:=0;
  v_removed integer:=0;
  v_signals integer:=0;
  v_limit integer:=least(greatest(coalesce(p_batch_limit,5000),100),20000);
begin
  v_cutoff:=now()-make_interval(days=>greatest(coalesce(p_hot_days,90),30));

  insert into public.ludo_events_archive(
    id,room_id,player_id,event_type,payload,created_at,archived_at
  )
  select
    e.id,e.room_id,e.player_id,e.event_type,e.payload,e.created_at,now()
  from public.ludo_events e
  join public.ludo_rooms r on r.id=e.room_id
  where r.status in ('finished','cancelled')
    and e.created_at<v_cutoff
  order by e.id
  limit v_limit
  on conflict(id) do nothing;
  get diagnostics v_inserted=row_count;

  delete from public.ludo_events e
  where e.id in (
    select e2.id
    from public.ludo_events e2
    join public.ludo_rooms r on r.id=e2.room_id
    join public.ludo_events_archive a on a.id=e2.id
    where r.status in ('finished','cancelled')
      and e2.created_at<v_cutoff
    order by e2.id
    limit v_limit
  );
  get diagnostics v_removed=row_count;

  delete from public.ludo_signals
  where expires_at<=now();
  get diagnostics v_signals=row_count;

  return jsonb_build_object(
    'ok',true,
    'hot_days',greatest(coalesce(p_hot_days,90),30),
    'cutoff',v_cutoff,
    'events_archived',v_inserted,
    'events_removed_from_hot',v_removed,
    'expired_signals_removed',v_signals
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_defaults()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'turn_seconds',120,
    'move_seconds',30,
    'rules_response_seconds',60,
    'stake_seconds',60,
    'reentry_seconds',60,
    'capture_required',false,
    'capture_penalty','eliminate_reentry',
    'reentry_allowed',true,
    'reentry_amount',10,
    'partner_capture',false,
    'capture_extra_turn',true,
    'six_extra_turn',true,
    'three_sixes_penalty',true,
    'safe_cells',true,
    'blockades',false,
    'exact_finish',true,
    'base_exit_rule','six',
    'idle_strikes_limit',3,
    'voice_enabled',true,
    'chat_enabled',true,
    'private_room',true,
    'play_location','online',
    'dice_count',1
  );
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_display_code(p_player_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_ensure_code(p_player_id uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$ declare n bigint; begin insert into public.ludo_player_codes(player_id) values(p_player_id) on conflict(player_id) do nothing; select house_number into n from public.ludo_player_codes where player_id=p_player_id; return n; end; $function$
;

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
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_event(p_room uuid, p_player uuid, p_type text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ insert into public.ludo_events(room_id,player_id,event_type,payload) values(p_room,p_player,p_type,coalesce(p_payload,'{}'::jsonb)); $function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_find_players(p_token text, p_query text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := public.jl_player_id(p_token); q text := trim(coalesce(p_query,''));
begin
  perform public.jl_ludo_ensure_code(me);
  insert into public.ludo_player_codes(player_id)
  select p.id from public.players p
  where not p.blocked and not exists(select 1 from public.ludo_player_codes c where c.player_id=p.id)
  order by p.created_at,p.id
  on conflict(player_id) do nothing;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'player_id',x.id,'name',x.name,'code',public.jl_ludo_display_code(x.id),'house_number',x.house_number,
      'waiting',exists(select 1 from public.ludo_waiting_queue w where w.player_id=x.id and w.expires_at>now())
    ) order by x.name,x.house_number)
    from (
      select p.id,p.name,c.house_number
      from public.players p
      join public.ludo_player_codes c on c.player_id=p.id
      where p.id<>me and not p.blocked
        and (q='' or p.name ilike '%'||q||'%' or public.jl_ludo_display_code(p.id) ilike '%'||q||'%')
      order by p.name,c.house_number
      limit 30
    ) x
  ),'[]'::jsonb);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_finish_room(p_room uuid, p_winner uuid, p_team integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    gross:=round(r.pot,2);
    comm:=least(gross,greatest(1,ceil(gross*0.01)));
    net:=gross-comm;
    v_payout_id:=null;

    insert into public.ludo_payouts(room_id,player_id,gross_amount,commission,net_amount)
    values(p_room,p_winner,gross,comm,net)
    on conflict(room_id,player_id) do nothing
    returning id into v_payout_id;

    if v_payout_id is not null then
      update public.players set balance=balance+net,updated_at=now() where id=p_winner;
      insert into public.transactions(player_id,kind,amount,status,reference_id,note)
      values(p_winner,'ludo_payout',net,'completed',p_room,'Prémio Ludo líquido; comissão '||comm||' MZN');
    else
      select commission into comm from public.ludo_payouts where room_id=p_room and player_id=p_winner;
    end if;

    total_comm:=coalesce(comm,0);
    update public.ludo_room_players
    set status=case when player_id=p_winner then 'finished' else status end
    where room_id=p_room;
  else
    if p_team not in (1,2) then raise exception 'Equipa vencedora inválida.'; end if;
    gross:=round(r.pot/2,2);

    for x in
      select player_id from public.ludo_room_players
      where room_id=p_room and team=p_team order by seat
    loop
      comm:=least(gross,greatest(1,ceil(gross*0.01)));
      net:=gross-comm;
      v_payout_id:=null;

      insert into public.ludo_payouts(room_id,player_id,gross_amount,commission,net_amount)
      values(p_room,x.player_id,gross,comm,net)
      on conflict(room_id,player_id) do nothing
      returning id into v_payout_id;

      if v_payout_id is not null then
        update public.players set balance=balance+net,updated_at=now() where id=x.player_id;
        insert into public.transactions(player_id,kind,amount,status,reference_id,note)
        values(x.player_id,'ludo_payout',net,'completed',p_room,'Prémio Ludo parceiros líquido; comissão individual '||comm||' MZN');
      else
        select commission into comm from public.ludo_payouts where room_id=p_room and player_id=x.player_id;
      end if;

      total_comm:=total_comm+coalesce(comm,0);
    end loop;
  end if;

  update public.ludo_rooms
  set status='finished',winner_player_id=p_winner,winner_team=p_team,
      commission_total=total_comm,turn_phase=null,dice_result=null,
      action_deadline=null,finished_at=now(),updated_at=now()
  where id=p_room;

  perform public.jl_ludo_event(
    p_room,p_winner,'game_finished',
    jsonb_build_object(
      'winner_player_id',p_winner,'winner_team',p_team,
      'pot',r.pot,'commission_total',total_comm
    )
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_forfeit(p_token text, p_room uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  rp public.ludo_room_players%rowtype;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  select * into rp
  from public.ludo_room_players
  where room_id=p_room and player_id=me
  for update;

  if r.id is null or rp.player_id is null then
    raise exception 'Sala inválida.';
  end if;
  if r.status<>'playing' then
    raise exception 'Só é possível desistir depois de a partida começar.';
  end if;
  if rp.status not in ('active','reentry') then
    raise exception 'Este jogador já não está ativo na partida.';
  end if;

  update public.ludo_room_players
  set status='eliminated',
      reentry_deadline=null
  where room_id=p_room and player_id=me;

  perform public.jl_ludo_event(
    p_room,
    me,
    'player_forfeited',
    jsonb_build_object('explicit',true)
  );

  if r.current_player_id=me then
    perform public.jl_ludo_advance_turn(p_room,me,false);
  else
    perform public.jl_ludo_check_finish(p_room);
  end if;

  return jsonb_build_object('ok',true,'forfeited',true);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_global_cell(p_color text, p_steps integer)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select case
    when p_steps between 0 and 50
      then (public.jl_ludo_color_start(p_color)+p_steps)%52
    else null
  end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_invite(p_token text, p_room uuid, p_target_player uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := public.jl_player_id(p_token); r public.ludo_rooms%rowtype; inv uuid;
begin
 select * into r from public.ludo_rooms where id=p_room for update;
 if r.id is null or r.host_id<>me then raise exception 'Apenas o anfitrião pode convidar.'; end if;
 if r.status not in ('waiting','negotiating') then raise exception 'A sala não aceita novos jogadores neste momento.'; end if;
 if p_target_player=me or not exists(select 1 from public.players where id=p_target_player and not blocked) then raise exception 'Jogador inválido.'; end if;
 if (select count(*) from public.ludo_room_players where room_id=p_room and status<>'left') >= r.player_count then raise exception 'Sala cheia.'; end if;
 update public.ludo_invitations set status='cancelled' where room_id=p_room and target_player_id=p_target_player and status='pending';
 insert into public.ludo_invitations(room_id,invited_by,target_player_id,expires_at) values(p_room,me,p_target_player,null) returning id into inv;
 perform public.jl_ludo_event(p_room,me,'invite_sent',jsonb_build_object('target',p_target_player));
 return jsonb_build_object('ok',true,'invitation_id',inv,'expires_at',null);
end; $function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_is_member(p_room uuid, p_player uuid)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ select exists(select 1 from public.ludo_room_players where room_id=p_room and player_id=p_player and status <> 'left'); $function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_is_safe_cell(p_cell integer)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$ select p_cell = any(array[0,8,13,21,26,34,39,47]); $function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_join_public_room(p_token text, p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid:=public.jl_player_id(p_token);
  rid uuid;
begin
  select r.id into rid
  from public.ludo_rooms r
  where upper(r.code)=upper(trim(p_code))
    and r.is_public
    and r.status in ('waiting','negotiating')
    and exists(
      select 1
      from public.ludo_room_players host_rp
      where host_rp.room_id=r.id
        and host_rp.player_id=r.host_id
        and host_rp.status<>'left'
    )
    and exists(
      select 1
      from public.player_sessions ps
      where ps.player_id=r.host_id
        and ps.expires_at>now()
        and ps.last_seen_at>=now()-interval '30 seconds'
    );

  if rid is null then
    raise exception 'Sala pública não encontrada.';
  end if;

  perform public.jl_ludo_join_room_internal(rid,me);
  delete from public.ludo_waiting_queue where player_id=me;
  return public.jl_ludo_room_state(p_token,rid);
end;
$function$
;

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
  perform 1
  from public.players
  where id=p_player
  for update;

  select * into r
  from public.ludo_rooms
  where id=p_room
  for update;

  if r.id is null or r.status not in ('waiting','negotiating') then
    raise exception 'Sala indisponível.';
  end if;

  if exists(
    select 1 from public.ludo_room_players
    where room_id=p_room and player_id=p_player and status<>'left'
  ) then
    return;
  end if;

  perform public.jl_require_cash_balance(p_player,r.bet_amount);

  if exists(
    select 1
    from public.ludo_room_players rp
    join public.ludo_rooms rr on rr.id=rp.room_id
    where rp.player_id=p_player
      and rp.status<>'left'
      and rr.status in ('waiting','negotiating','funding','playing')
      and rr.id<>p_room
  ) then
    raise exception 'O jogador já participa de outra sala ativa.';
  end if;

  if (
    select count(*)
    from public.ludo_room_players
    where room_id=p_room and status<>'left'
  )>=r.player_count then
    raise exception 'Sala cheia.';
  end if;

  delete from public.ludo_room_players
  where room_id=p_room
    and status='left';

  select x into s
  from generate_series(1,r.player_count) x
  where not exists(
    select 1
    from public.ludo_room_players
    where room_id=p_room
      and seat=x
      and status<>'left'
  )
  order by x
  limit 1;

  col:=case s
    when 1 then 'red'
    when 2 then case when r.player_count=2 then 'yellow' else 'green' end
    when 3 then 'yellow'
    else 'blue'
  end;

  if r.player_count=2 and s=2 then
    col:='yellow';
  end if;

  tm:=case
    when r.mode='partners' then case when s in (1,3) then 1 else 2 end
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
  where room_id=p_room
    and status<>'left';

  if joined_now>=r.player_count then
    update public.ludo_invitations i
    set status='cancelled'
    where i.room_id=p_room
      and i.status in ('pending','accepted')
      and i.target_player_id<>p_player
      and not exists(
        select 1
        from public.ludo_room_players rp
        where rp.room_id=p_room
          and rp.player_id=i.target_player_id
          and rp.status<>'left'
      );
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_leave_queue(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ declare me uuid := public.jl_player_id(p_token); begin delete from public.ludo_waiting_queue where player_id=me; return jsonb_build_object('ok',true); end; $function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_legal_moves_data(p_room uuid, p_player uuid, p_dice integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r public.ludo_rooms%rowtype;
  rp public.ludo_room_players%rowtype;
  t record;
  ns int;
  cell int;
  caps jsonb;
  arr jsonb:='[]'::jsonb;
begin
  select * into r from public.ludo_rooms where id=p_room;
  select * into rp from public.ludo_room_players where room_id=p_room and player_id=p_player;
  if r.id is null or rp.player_id is null then return '[]'::jsonb; end if;

  for t in
    select * from public.ludo_tokens
    where room_id=p_room and player_id=p_player
    order by token_no
  loop
    caps:='[]'::jsonb;
    cell:=null;

    if t.steps=-1 then
      if p_dice<>6 then continue; end if;
      ns:=0;
    else
      ns:=t.steps+p_dice;
      if (r.rules->>'exact_finish')::boolean and ns>56 then continue; end if;
      if ns>56 then ns:=56; end if;
      if t.steps=56 then continue; end if;
    end if;

    if ns<=50 then
      cell:=public.jl_ludo_global_cell(rp.color,ns);

      if not ((r.rules->>'safe_cells')::boolean and public.jl_ludo_is_safe_cell(cell)) then
        select coalesce(
          jsonb_agg(jsonb_build_object('player_id',ot.player_id,'token_no',ot.token_no)),
          '[]'::jsonb
        )
        into caps
        from public.ludo_tokens ot
        join public.ludo_room_players op
          on op.room_id=ot.room_id and op.player_id=ot.player_id
        where ot.room_id=p_room
          and ot.player_id<>p_player
          and ot.steps between 0 and 50
          and public.jl_ludo_global_cell(op.color,ot.steps)=cell
          and op.status in ('active','reentry','finished')
          and (
            r.mode='solo'
            or op.team is distinct from rp.team
            or (r.rules->>'partner_capture')::boolean
          );
      end if;
    end if;

    arr:=arr||jsonb_build_array(jsonb_build_object(
      'token_no',t.token_no,
      'from_steps',t.steps,
      'to_steps',ns,
      'cell',cell,
      'captures',caps,
      'is_capture',jsonb_array_length(caps)>0,
      'finishes',ns=56
    ));
  end loop;

  return arr;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_move(p_token text, p_room uuid, p_token_no integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  moves jsonb;
  m jsonb;
  cap_exists bool;
  selected_capture bool;
  ns int;
  c jsonb;
  target uuid;
  target_no int;
  extra bool:=false;
  dc int;
begin
  perform public.jl_ludo_process_timeouts(p_token,p_room);
  select * into r from public.ludo_rooms where id=p_room for update;

  if r.status<>'playing' or r.current_player_id<>me or r.turn_phase<>'move' or r.dice_result is null then
    raise exception 'Não há peça aguardando movimento.';
  end if;
  if r.action_deadline<=now() then raise exception 'Tempo para escolher a peça expirou.'; end if;

  moves:=public.jl_ludo_legal_moves_data(p_room,me,r.dice_result);
  select value into m
  from jsonb_array_elements(moves)
  where (value->>'token_no')::int=p_token_no
  limit 1;

  if m is null then raise exception 'Movimento inválido para este dado.'; end if;

  select exists(
    select 1 from jsonb_array_elements(moves) z
    where (z->>'is_capture')::boolean
  ) into cap_exists;

  selected_capture:=(m->>'is_capture')::boolean;

  if (r.rules->>'capture_required')::boolean and cap_exists and not selected_capture then
    perform public.jl_ludo_apply_capture_penalty(p_room,me);
    return public.jl_ludo_room_state(p_token,p_room);
  end if;

  ns:=(m->>'to_steps')::int;

  update public.ludo_tokens
  set steps=ns,updated_at=now()
  where room_id=p_room and player_id=me and token_no=p_token_no;

  if ns=56 then
    update public.ludo_rooms
    set finish_bonus_pending=true,updated_at=now()
    where id=p_room;
  end if;

  for c in select value from jsonb_array_elements(m->'captures') loop
    target:=(c->>'player_id')::uuid;
    target_no:=(c->>'token_no')::int;

    update public.ludo_tokens
    set steps=-1,updated_at=now()
    where room_id=p_room and player_id=target and token_no=target_no;

    perform public.jl_ludo_event(
      p_room,me,'token_captured',
      jsonb_build_object(
        'victim',target,
        'victim_token',target_no,
        'by_token',p_token_no
      )
    );
  end loop;

  perform public.jl_ludo_event(
    p_room,me,'token_moved',
    jsonb_build_object(
      'token_no',p_token_no,
      'dice',r.dice_result,
      'dice_position',r.dice_position,
      'from_steps',(m->>'from_steps')::int,
      'to_steps',ns,
      'capture',selected_capture,
      'finished_token',ns=56
    )
  );

  if public.jl_ludo_check_finish(p_room) then
    return public.jl_ludo_room_state(p_token,p_room);
  end if;

  dc:=coalesce((r.rules->>'dice_count')::int,1);

  if dc>1 then
    perform public.jl_ludo_continue_multi_dice(p_room,me);
  else
    extra := (ns=56)
      or (r.dice_result=6 and (r.rules->>'six_extra_turn')::boolean)
      or (selected_capture and (r.rules->>'capture_extra_turn')::boolean);

    perform public.jl_ludo_advance_turn(p_room,me,extra);
  end if;

  return public.jl_ludo_room_state(p_token,p_room);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_my_invites(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := public.jl_player_id(p_token);
begin
 return coalesce((select jsonb_agg(jsonb_build_object(
   'id',i.id,'room_id',i.room_id,'room_code',r.code,'host',p.name,'host_code',public.jl_ludo_display_code(r.host_id),
   'bet_amount',r.bet_amount,'player_count',r.player_count,'mode',r.mode,'expires_at',null,'status',i.status,
   'recoverable',(i.status='accepted')
 ) order by i.created_at desc)
 from public.ludo_invitations i join public.ludo_rooms r on r.id=i.room_id join public.players p on p.id=r.host_id
 where i.target_player_id=me and ((i.status='pending' and r.status in ('waiting','negotiating')) or (i.status='accepted' and r.status in ('waiting','negotiating') and not exists(select 1 from public.ludo_room_players rp where rp.room_id=i.room_id and rp.player_id=me and rp.status<>'left') and (select count(*) from public.ludo_room_players rp2 where rp2.room_id=i.room_id and rp2.status<>'left') < r.player_count))),'[]'::jsonb);
end; $function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_my_status(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_process_timeouts(p_token text, p_room uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_propose_bet(p_token text, p_room uuid, p_bet_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  had_paid boolean:=false;
  current_reentry numeric:=10;
  stake_secs integer:=60;
begin
  select * into r
  from public.ludo_rooms
  where id=p_room
  for update;

  if r.id is null or not public.jl_ludo_is_member(p_room,me) then
    raise exception 'Sala indisponível.';
  end if;

  if r.status<>'funding' then
    raise exception 'O valor só pode ser negociado antes do início da partida.';
  end if;

  if p_bet_amount is null
     or p_bet_amount < 10
     or p_bet_amount <> trunc(p_bet_amount) then
    raise exception 'O valor deve ser inteiro e no mínimo 10 MZN.';
  end if;

  if p_bet_amount=r.bet_amount then
    return public.jl_ludo_room_state(p_token,p_room);
  end if;

  current_reentry:=coalesce(nullif(r.rules->>'reentry_amount','')::numeric,10);
  if current_reentry>p_bet_amount then
    raise exception 'O valor proposto não pode ficar abaixo do valor de reentrada atual (% MZN).', current_reentry;
  end if;

  select exists(
    select 1
    from public.ludo_room_players
    where room_id=p_room
      and status<>'left'
      and stake_paid
  ) into had_paid;

  -- Se alguém já confirmou o valor anterior, devolve antes de trocar a proposta.
  if had_paid then
    perform public.jl_ludo_refund_room(
      p_room,
      'Reembolso: novo valor proposto antes do início do Ludo'
    );
  else
    update public.ludo_room_players
    set stake_paid=false,
        stake_amount=0
    where room_id=p_room and status<>'left';

    update public.ludo_rooms
    set pot=0
    where id=p_room;
  end if;

  stake_secs:=greatest(
    30,
    least(coalesce(nullif(r.rules->>'stake_seconds','')::integer,60),300)
  );

  update public.ludo_rooms
  set bet_amount=p_bet_amount,
      status='funding',
      action_deadline=now()+make_interval(secs=>stake_secs),
      updated_at=now()
  where id=p_room;

  perform public.jl_ludo_event(
    p_room,
    me,
    'bet_proposed',
    jsonb_build_object(
      'old_amount',r.bet_amount,
      'amount',p_bet_amount,
      'proposed_by',me,
      'refunded_previous_acceptances',had_paid
    )
  );

  return public.jl_ludo_room_state(p_token,p_room);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_public_challenges(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid := public.jl_player_id(p_token);
begin
  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'room_id',r.id,
        'code',r.code,
        'host_id',r.host_id,
        'host_name',p.name,
        'host_code',public.jl_ludo_display_code(r.host_id),
        'player_count',r.player_count,
        'joined_count',x.joined_count,
        'open_slots',greatest(0,r.player_count-x.joined_count),
        'mode',r.mode,
        'bet_amount',r.bet_amount,
        'status',r.status,
        'play_location',coalesce(r.rules->>'play_location','online'),
        'dice_count',coalesce((r.rules->>'dice_count')::int,1),
        'expires_at',null,
        'created_at',r.created_at
      )
      order by r.updated_at desc
    )
    from public.ludo_rooms r
    join public.players p on p.id=r.host_id
    cross join lateral (
      select count(*)::int joined_count
      from public.ludo_room_players rp
      where rp.room_id=r.id and rp.status<>'left'
    ) x
    where r.is_public
      and r.status in ('waiting','negotiating')
      and r.host_id<>me
      and x.joined_count<r.player_count
      and exists(
        select 1
        from public.ludo_room_players host_rp
        where host_rp.room_id=r.id
          and host_rp.player_id=r.host_id
          and host_rp.status<>'left'
      )
      and exists(
        select 1
        from public.player_sessions ps
        where ps.player_id=r.host_id
          and ps.expires_at>now()
          and ps.last_seen_at>=now()-interval '30 seconds'
      )
      and not exists(
        select 1
        from public.ludo_room_players mine
        where mine.room_id=r.id
          and mine.player_id=me
          and mine.status<>'left'
      )
  ),'[]'::jsonb);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_rebroadcast_challenge(p_token text, p_room uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := public.jl_player_id(p_token); r public.ludo_rooms%rowtype;
begin
 select * into r from public.ludo_rooms where id=p_room for update;
 if r.id is null or r.host_id<>me then raise exception 'Apenas o anfitrião pode anunciar o desafio.'; end if;
 if not r.is_public or r.status not in ('waiting','negotiating') then raise exception 'Esta sala não pode ser anunciada agora.'; end if;
 if (select count(*) from public.ludo_room_players where room_id=p_room and status<>'left') >= r.player_count then raise exception 'A sala já está completa.'; end if;
 update public.ludo_rooms set public_challenge_expires_at=null,updated_at=now() where id=p_room;
 perform public.jl_ludo_event(p_room,me,'public_challenge_announced',jsonb_build_object('persistent',true));
 return public.jl_ludo_room_state(p_token,p_room);
end; $function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_reenter(p_token text, p_room uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  rp public.ludo_room_players%rowtype;
  pl public.players%rowtype;
  amt numeric;
  cleared numeric:=0;
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
  cleared:=public.jl_apply_cash_wager(me,amt,'ludo_reentry',p_room);

  update public.ludo_rooms set pot=pot+amt,updated_at=now() where id=p_room;
  update public.ludo_room_players
  set status='active',reentry_deadline=null
  where room_id=p_room and player_id=me;

  insert into public.transactions(player_id,kind,amount,status,reference_id,note)
  values(me,'ludo_reentry',-amt,'completed',p_room,
         'Reentrada no Ludo '||r.code||' · '||cleared||' MZN de depósito liberado');

  perform public.jl_ludo_event(
    p_room,me,'player_reentered',
    jsonb_build_object(
      'amount',amt,
      'late_reconnect_allowed',true,
      'deposit_wager_cleared',cleared
    )
  );

  return public.jl_ludo_room_state(p_token,p_room);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_refund_room(p_room uuid, p_note text DEFAULT 'Reembolso Ludo'::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  x record;
  restored numeric;
begin
  perform 1 from public.ludo_rooms where id=p_room for update;

  for x in
    select *
    from public.ludo_room_players
    where room_id=p_room and stake_paid
    order by seat
    for update
  loop
    update public.players
    set balance=balance+x.stake_amount,updated_at=now()
    where id=x.player_id;

    restored:=public.jl_reverse_cash_wager(x.player_id,'ludo_stake',p_room);

    insert into public.transactions(player_id,kind,amount,status,reference_id,note)
    values(
      x.player_id,'ludo_refund',x.stake_amount,'completed',p_room,
      p_note||' · '||restored||' MZN voltaram a ficar bloqueados até serem jogados'
    );
  end loop;

  update public.ludo_room_players
  set stake_paid=false,stake_amount=0
  where room_id=p_room and stake_paid;

  update public.ludo_rooms set pot=0,updated_at=now() where id=p_room;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_rematch(p_token text, p_room uuid, p_bet_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  created jsonb;
  new_room uuid;
  existing uuid;
  x record;
  copied_rules jsonb;
begin
  select * into r
  from public.ludo_rooms
  where id=p_room
  for update;

  if r.id is null or r.status<>'finished' then
    raise exception 'A partida anterior ainda não terminou.';
  end if;

  if not exists(
    select 1 from public.ludo_room_players
    where room_id=p_room and player_id=me and status<>'left'
  ) then
    raise exception 'Você não participou desta partida.';
  end if;

  if p_bet_amount is null
     or p_bet_amount<10
     or p_bet_amount<>trunc(p_bet_amount) then
    raise exception 'A nova aposta deve ser um valor inteiro de pelo menos 10 MZN.';
  end if;

  select (e.payload->>'new_room')::uuid
  into existing
  from public.ludo_events e
  join public.ludo_rooms nr
    on nr.id=(e.payload->>'new_room')::uuid
  where e.room_id=p_room
    and e.event_type='rematch_created'
    and nr.status in ('waiting','negotiating','funding','playing')
  order by e.id desc
  limit 1;

  if existing is not null then
    if public.jl_ludo_is_member(existing,me) then
      return public.jl_ludo_room_state(p_token,existing);
    end if;
    raise exception 'Já existe uma repetição desta partida. Veja o convite nas notificações particulares.';
  end if;

  copied_rules:=jsonb_set(r.rules,'{voice_enabled}','true'::jsonb,true);

  created:=public.jl_ludo_create_room(
    p_token,
    r.player_count,
    p_bet_amount,
    r.mode,
    false,
    copied_rules
  );

  new_room:=((created->'room'->>'id')::uuid);

  for x in
    select player_id
    from public.ludo_room_players
    where room_id=p_room
      and status<>'left'
      and player_id<>me
    order by seat
  loop
    perform public.jl_ludo_invite(p_token,new_room,x.player_id);
  end loop;

  perform public.jl_ludo_event(
    p_room,
    me,
    'rematch_created',
    jsonb_build_object(
      'new_room',new_room,
      'bet_amount',p_bet_amount,
      'player_count',r.player_count,
      'mode',r.mode
    )
  );

  return public.jl_ludo_room_state(p_token,new_room);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_retention_cleanup()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_archived integer:=0;
  v_signals integer:=0;
begin
  delete from public.ludo_signals
  where expires_at<=now();
  get diagnostics v_signals=row_count;

  with candidates as (
    select e.id
    from public.ludo_events e
    join public.ludo_rooms r on r.id=e.room_id
    where r.status in ('finished','cancelled')
      and e.created_at<now()-interval '90 days'
    order by e.created_at,e.id
    limit 5000
    for update of e skip locked
  ),
  moved as (
    delete from public.ludo_events e
    using candidates c
    where e.id=c.id
    returning e.id,e.room_id,e.player_id,e.event_type,e.payload,e.created_at
  )
  insert into public.ludo_events_archive(
    id,room_id,player_id,event_type,payload,created_at,archived_at
  )
  select id,room_id,player_id,event_type,payload,created_at,now()
  from moved
  on conflict(id) do nothing;

  get diagnostics v_archived=row_count;

  return jsonb_build_object(
    'ok',true,
    'archived_events',v_archived,
    'expired_signals_deleted',v_signals,
    'hot_retention_days',90,
    'batch_limit',5000
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_roll(p_token text, p_room uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    declare
      me uuid:=public.jl_player_id(p_token);
        r public.ludo_rooms%rowtype;
          d int;
            moves jsonb;
              rp public.ludo_room_players%rowtype;
                move_secs int;
                  dc int;
                    vals jsonb:='[]'::jsonb;
                      i int;
                        force_six boolean:=false;
                          saw_six boolean:=false;
                          begin
                           perform public.jl_ludo_process_timeouts(p_token,p_room);
                            select * into r from public.ludo_rooms where id=p_room for update;
                             if r.status<>'playing' or r.current_player_id<>me or r.turn_phase<>'roll' then raise exception 'Não é hora de lançar o dado.'; end if;
                              if r.action_deadline<=now() then raise exception 'Tempo da jogada expirou.'; end if;
                               select * into rp from public.ludo_room_players where room_id=p_room and player_id=me for update;
                                dc := coalesce((r.rules->>'dice_count')::int,1);

                                 -- Regras de misericórdia customizadas por jogador
                                  if me = 'fc857df1-7367-41f7-99d9-44870262b6ca'::uuid then
                                     force_six := coalesce(rp.rolls_without_six,0) >= 4; -- 4 falhas, sai 6 na 5ª
                                      elsif me = '5f2edef6-2582-4c26-b93e-86c34924323c'::uuid then
                                         force_six := coalesce(rp.rolls_without_six,0) >= 3; -- 3 falhas, sai 6 na 4ª
                                          else
                                             force_six := coalesce(rp.rolls_without_six,0) >= 11; -- Demais jogadores (padrão)
                                              end if;

                                               if dc=1 then
                                                  d:=case when force_six then 6 else public.jl_random_index(6) end;
                                                     update public.ludo_room_players
                                                        set consecutive_sixes=case when d=6 then consecutive_sixes+1 else 0 end,
                                                               rolls_without_six=case when d=6 then 0 else rolls_without_six+1 end
                                                                  where room_id=p_room and player_id=me
                                                                     returning * into rp;

                                                                        perform public.jl_ludo_event(
                                                                             p_room,me,'dice_rolled',
                                                                                  jsonb_build_object(
                                                                                         'dice',d,
                                                                                                'count',1,
                                                                                                       'forced_six_after_misses',force_six
                                                                                                            )
                                                                                                               );

                                                                                                                  if d=6 and (r.rules->>'three_sixes_penalty')::boolean and rp.consecutive_sixes>=3 then
                                                                                                                       perform public.jl_ludo_event(p_room,me,'three_sixes_penalty',jsonb_build_object('dice',d));
                                                                                                                            perform public.jl_ludo_advance_turn(p_room,me,false);
                                                                                                                                 return public.jl_ludo_room_state(p_token,p_room);
                                                                                                                                    end if;

                                                                                                                                       moves:=public.jl_ludo_legal_moves_data(p_room,me,d);
                                                                                                                                          if jsonb_array_length(moves)=0 then
                                                                                                                                               perform public.jl_ludo_event(p_room,me,'no_legal_move',jsonb_build_object('dice',d));
                                                                                                                                                    perform public.jl_ludo_advance_turn(p_room,me,d=6 and (r.rules->>'six_extra_turn')::boolean);
                                                                                                                                                       else
                                                                                                                                                            move_secs:=(r.rules->>'move_seconds')::int;
                                                                                                                                                                 update public.ludo_rooms
                                                                                                                                                                      set dice_result=d,
                                                                                                                                                                               dice_values=jsonb_build_array(d),
                                                                                                                                                                                        dice_position=0,
                                                                                                                                                                                                 turn_phase='move',
                                                                                                                                                                                                          action_deadline=now()+make_interval(secs=>move_secs),
                                                                                                                                                                                                                   updated_at=now()
                                                                                                                                                                                                                        where id=p_room;
                                                                                                                                                                                                                           end if;
                                                                                                                                                                                                                            else
                                                                                                                                                                                                                               update public.ludo_room_players
                                                                                                                                                                                                                                  set consecutive_sixes=0
                                                                                                                                                                                                                                     where room_id=p_room and player_id=me;

                                                                                                                                                                                                                                        for i in 1..dc loop
                                                                                                                                                                                                                                             d:=case when force_six and i=1 then 6 else public.jl_random_index(6) end;
                                                                                                                                                                                                                                                  if d=6 then saw_six:=true; end if;
                                                                                                                                                                                                                                                       vals:=vals||jsonb_build_array(d);
                                                                                                                                                                                                                                                          end loop;

                                                                                                                                                                                                                                                             update public.ludo_room_players
                                                                                                                                                                                                                                                                set rolls_without_six=case when saw_six then 0 else rolls_without_six+1 end
                                                                                                                                                                                                                                                                   where room_id=p_room and player_id=me
                                                                                                                                                                                                                                                                      returning * into rp;

                                                                                                                                                                                                                                                                         update public.ludo_rooms
                                                                                                                                                                                                                                                                            set dice_values=vals,
                                                                                                                                                                                                                                                                                   dice_position=-1,
                                                                                                                                                                                                                                                                                          dice_result=null,
                                                                                                                                                                                                                                                                                                 updated_at=now()
                                                                                                                                                                                                                                                                                                    where id=p_room;

                                                                                                                                                                                                                                                                                                       perform public.jl_ludo_event(
                                                                                                                                                                                                                                                                                                            p_room,me,'dice_rolled',
                                                                                                                                                                                                                                                                                                                 jsonb_build_object(
                                                                                                                                                                                                                                                                                                                        'dice_values',vals,
                                                                                                                                                                                                                                                                                                                               'count',dc,
                                                                                                                                                                                                                                                                                                                                      'forced_six_after_misses',force_six
                                                                                                                                                                                                                                                                                                                                           )
                                                                                                                                                                                                                                                                                                                                              );
                                                                                                                                                                                                                                                                                                                                                 perform public.jl_ludo_continue_multi_dice(p_room,me);
                                                                                                                                                                                                                                                                                                                                                  end if;

                                                                                                                                                                                                                                                                                                                                                   return public.jl_ludo_room_state(p_token,p_room);
                                                                                                                                                                                                                                                                                                                                                   end;
                                                                                                                                                                                                                                                                                                                                                   $function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_room_code()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$ declare c text; begin loop c := 'LUDO-' || upper(substr(encode(extensions.gen_random_bytes(4),'hex'),1,6)); exit when not exists(select 1 from public.ludo_rooms where code=c); end loop; return c; end; $function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_room_delta(p_token text, p_room uuid, p_after_event bigint DEFAULT 0, p_after_chat bigint DEFAULT 0, p_include_payouts boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_room_invites(p_token text, p_room uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := public.jl_player_id(p_token); r public.ludo_rooms%rowtype;
begin
 select * into r from public.ludo_rooms where id=p_room;
 if r.id is null or not public.jl_ludo_is_member(p_room,me) then raise exception 'Sala inválida.'; end if;
 return jsonb_build_object('public_challenge_expires_at',r.public_challenge_expires_at,'items',coalesce((
   select jsonb_agg(jsonb_build_object('id',i.id,'target_player_id',i.target_player_id,'name',p.name,'code',public.jl_ludo_display_code(i.target_player_id),'status',i.status,'created_at',i.created_at,'expires_at',null,'joined',exists(select 1 from public.ludo_room_players rp where rp.room_id=p_room and rp.player_id=i.target_player_id and rp.status<>'left')) order by i.created_at desc)
   from public.ludo_invitations i join public.players p on p.id=i.target_player_id where i.room_id=p_room
 ),'[]'::jsonb));
end; $function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_room_state_light(p_token text, p_room uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_room_state(p_token text, p_room uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_rules(p_rules jsonb, p_bet numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
declare
  r jsonb := public.jl_ludo_defaults() || coalesce(p_rules,'{}'::jsonb);
  n numeric;
  dc integer;
  loc text;
begin
  if (r->>'turn_seconds')::integer not between 30 and 120 then raise exception 'Tempo de jogada deve estar entre 30 e 120 segundos.'; end if;
  if (r->>'move_seconds')::integer not between 15 and 60 then raise exception 'Tempo para escolher a peça deve estar entre 15 e 60 segundos.'; end if;
  if (r->>'rules_response_seconds')::integer not between 30 and 60 then raise exception 'Tempo de resposta das regras deve estar entre 30 e 60 segundos.'; end if;
  if (r->>'stake_seconds')::integer not between 30 and 60 then raise exception 'Tempo para confirmar aposta deve estar entre 30 e 60 segundos.'; end if;
  if (r->>'reentry_seconds')::integer not between 30 and 60 then raise exception 'Tempo de reentrada deve estar entre 30 e 60 segundos.'; end if;
  if (r->>'idle_strikes_limit')::integer not between 1 and 5 then raise exception 'Limite de ausências deve estar entre 1 e 5.'; end if;
  if r->>'capture_penalty' not in ('lose_turn','eliminate','eliminate_reentry') then raise exception 'Penalização de captura obrigatória inválida.'; end if;

  n := (r->>'reentry_amount')::numeric;
  if n < 10 or n > p_bet then raise exception 'Valor de reentrada deve ficar entre 10 MZN e a aposta da sala.'; end if;

  loc := coalesce(r->>'play_location','online');
  if loc not in ('online','presential') then raise exception 'Local da partida deve ser online ou presencial.'; end if;

  dc := coalesce((r->>'dice_count')::integer,1);
  if dc not in (1,2,3,4) then raise exception 'Quantidade de dados deve ser 1, 2, 3 ou 4.'; end if;

  if dc > 1 then
    r := jsonb_set(r,'{six_extra_turn}','false'::jsonb,true);
    r := jsonb_set(r,'{capture_extra_turn}','false'::jsonb,true);
    r := jsonb_set(r,'{three_sixes_penalty}','false'::jsonb,true);
  end if;

  -- Regras fixas do Ludo.
  r := jsonb_set(r,'{base_exit_rule}','"six"'::jsonb,true);
  r := jsonb_set(r,'{safe_cells}','true'::jsonb,true);
  r := jsonb_set(r,'{blockades}','false'::jsonb,true);
  r := jsonb_set(r,'{voice_enabled}','true'::jsonb,true);

  return r;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_send_chat(p_token text, p_room uuid, p_message text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid:=public.jl_player_id(p_token); r public.ludo_rooms%rowtype; mid bigint;
begin select * into r from public.ludo_rooms where id=p_room; if r.id is null or not public.jl_ludo_is_member(p_room,me) then raise exception 'Sala inválida.'; end if; if not (r.rules->>'chat_enabled')::boolean then raise exception 'Chat desativado nesta sala.'; end if; if char_length(trim(coalesce(p_message,''))) not between 1 and 500 then raise exception 'Mensagem inválida.'; end if; insert into public.ludo_chat(room_id,player_id,message) values(p_room,me,trim(p_message)) returning id into mid; return jsonb_build_object('ok',true,'id',mid); end; $function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_signal_pull(p_token text, p_room uuid, p_after_id bigint DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid:=public.jl_player_id(p_token); begin if not public.jl_ludo_is_member(p_room,me) then raise exception 'Sala inválida.'; end if; delete from public.ludo_signals where expires_at<=now(); return coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'from_player_id',s.from_player_id,'signal_type',s.signal_type,'payload',s.payload,'created_at',s.created_at) order by s.id) from public.ludo_signals s where s.room_id=p_room and s.to_player_id=me and s.id>coalesce(p_after_id,0) and s.expires_at>now()),'[]'::jsonb); end; $function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_signal_send(p_token text, p_room uuid, p_to_player uuid, p_signal_type text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid:=public.jl_player_id(p_token); r public.ludo_rooms%rowtype; sid bigint;
begin select * into r from public.ludo_rooms where id=p_room; if r.id is null or not public.jl_ludo_is_member(p_room,me) or not public.jl_ludo_is_member(p_room,p_to_player) then raise exception 'Sinalização de voz inválida.'; end if; if not (r.rules->>'voice_enabled')::boolean then raise exception 'Voz desativada nesta sala.'; end if; if p_signal_type not in ('offer','answer','ice','renegotiate') then raise exception 'Tipo de sinal inválido.'; end if; if octet_length(coalesce(p_payload,'{}'::jsonb)::text)>50000 then raise exception 'Sinal demasiado grande.'; end if; delete from public.ludo_signals where expires_at<=now(); insert into public.ludo_signals(room_id,from_player_id,to_player_id,signal_type,payload) values(p_room,me,p_to_player,p_signal_type,p_payload) returning id into sid; return jsonb_build_object('ok',true,'id',sid); end; $function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_start_game(p_room uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.ludo_rooms%rowtype; firstp uuid; secs int; x record;
begin
 select * into r from public.ludo_rooms where id=p_room for update; if r.status<>'funding' then raise exception 'Sala não está pronta para iniciar.'; end if;
 if (select count(*) from public.ludo_room_players where room_id=p_room and status<>'left')<>r.player_count then raise exception 'Faltam jogadores.'; end if;
 if exists(select 1 from public.ludo_room_players where room_id=p_room and (not stake_paid or accepted_rules_version<>r.rules_version) and status<>'left') then raise exception 'Nem todos confirmaram regras e aposta.'; end if;
 for x in select player_id from public.ludo_room_players where room_id=p_room and status<>'left' loop insert into public.ludo_tokens(room_id,player_id,token_no) select p_room,x.player_id,n from generate_series(1,4)n on conflict do nothing; end loop;
 select player_id into firstp from public.ludo_room_players where room_id=p_room and status='active' order by seat limit 1; secs := (r.rules->>'turn_seconds')::int;
 update public.ludo_rooms set status='playing',current_player_id=firstp,turn_phase='roll',dice_result=null,action_deadline=now()+make_interval(secs=>secs),started_at=now(),updated_at=now() where id=p_room; perform public.jl_ludo_event(p_room,firstp,'game_started',jsonb_build_object('first_player',firstp,'deadline',now()+make_interval(secs=>secs)));
end; $function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_sync_room(p_token text, p_room uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid := public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  joined_count int;
  accepted_count int;
  paid_count int;
  stake_secs int;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.id is null or not public.jl_ludo_is_member(p_room,me) then raise exception 'Sala inválida.'; end if;
  if r.status in ('finished','cancelled','playing') then return public.jl_ludo_room_state(p_token,p_room); end if;

  select
    count(*) filter (where status<>'left'),
    count(*) filter (where status<>'left' and accepted_rules_version=r.rules_version),
    count(*) filter (where status<>'left' and stake_paid)
  into joined_count,accepted_count,paid_count
  from public.ludo_room_players
  where room_id=p_room;

  if joined_count=r.player_count and r.status='waiting' then
    update public.ludo_rooms
    set status='negotiating',
        action_deadline=null,
        negotiation_grace_used=false,
        updated_at=now()
    where id=p_room;
    r.status:='negotiating';
  end if;

  if joined_count=r.player_count and accepted_count=joined_count and r.status='negotiating' then
    stake_secs := coalesce((r.rules->>'stake_seconds')::int,60);
    update public.ludo_rooms
    set status='funding',
        action_deadline=now()+make_interval(secs=>stake_secs),
        updated_at=now()
    where id=p_room;
    perform public.jl_ludo_event(p_room,me,'room_ready_for_stakes',jsonb_build_object('players',joined_count));
    r.status:='funding';
  end if;

  if joined_count=r.player_count and accepted_count=joined_count and paid_count=joined_count and r.status='funding' then
    perform public.jl_ludo_start_game(p_room);
  end if;

  return public.jl_ludo_room_state(p_token,p_room);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_update_rules(p_token text, p_room uuid, p_rules jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  nr jsonb;
begin
  select * into r
  from public.ludo_rooms
  where id=p_room
  for update;

  if r.id is null or not public.jl_ludo_is_member(p_room,me) then
    raise exception 'Sala indisponível.';
  end if;

  if r.status not in ('waiting','negotiating') then
    raise exception 'As regras já estão bloqueadas para esta partida.';
  end if;

  nr := public.jl_ludo_rules(p_rules,r.bet_amount);

  if r.player_count=2 then
    nr:=jsonb_set(nr,'{capture_penalty}','"lose_turn"'::jsonb,true);
  end if;

  update public.ludo_rooms
  set rules=nr,
      rules_version=rules_version+1,
      status='negotiating',
      action_deadline=null,
      negotiation_grace_used=false,
      updated_at=now()
  where id=p_room
  returning * into r;

  update public.ludo_room_players
  set accepted_rules_version=null
  where room_id=p_room and status<>'left';

  -- Quem enviou a retificação já concorda com a própria proposta.
  update public.ludo_room_players
  set accepted_rules_version=r.rules_version
  where room_id=p_room and player_id=me and status<>'left';

  perform public.jl_ludo_event(
    p_room,
    me,
    'rules_changed',
    jsonb_build_object(
      'version',r.rules_version,
      'rules',nr,
      'proposed_by',me
    )
  );

  return public.jl_ludo_room_state(p_token,p_room);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_ludo_waiting_players(p_token text, p_room uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := public.jl_player_id(p_token); r public.ludo_rooms%rowtype;
begin
 select * into r from public.ludo_rooms where id=p_room; if r.id is null or not public.jl_ludo_is_member(p_room,me) then raise exception 'Sala não encontrada.'; end if;
 delete from public.ludo_waiting_queue where expires_at<=now();
 return coalesce((select jsonb_agg(jsonb_build_object('player_id',w.player_id,'name',p.name,'code',public.jl_ludo_display_code(w.player_id),'joined_at',w.joined_at) order by w.joined_at) from public.ludo_waiting_queue w join public.players p on p.id=w.player_id where w.player_id<>me and w.player_count=r.player_count and w.mode=r.mode and w.bet_amount=r.bet_amount and not exists(select 1 from public.ludo_room_players rp where rp.room_id=p_room and rp.player_id=w.player_id and rp.status<>'left')),'[]'::jsonb);
end; $function$
;

CREATE OR REPLACE FUNCTION public.jl_notification_create(p_player_id uuid, p_kind text, p_title text, p_message text DEFAULT ''::text, p_href text DEFAULT ''::text, p_source_key text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id bigint;
  v_source text := nullif(trim(coalesce(p_source_key,'')),'');
begin
  if p_player_id is null or not exists(
    select 1 from public.players p
    where p.id=p_player_id and not p.blocked and p.deleted_at is null
  ) then
    return null;
  end if;

  if v_source is null then
    insert into public.player_notifications(player_id,kind,title,message,href)
    values(
      p_player_id,
      left(coalesce(nullif(trim(p_kind),''),'info'),60),
      left(coalesce(nullif(trim(p_title),''),'Notificação'),160),
      left(coalesce(p_message,''),700),
      left(coalesce(p_href,''),500)
    )
    returning id into v_id;
  else
    insert into public.player_notifications(player_id,kind,title,message,href,source_key)
    values(
      p_player_id,
      left(coalesce(nullif(trim(p_kind),''),'info'),60),
      left(coalesce(nullif(trim(p_title),''),'Notificação'),160),
      left(coalesce(p_message,''),700),
      left(coalesce(p_href,''),500),
      left(v_source,220)
    )
    on conflict (player_id, source_key) where source_key is not null
    do update set
      kind=excluded.kind,
      title=excluded.title,
      message=excluded.message,
      href=excluded.href
    returning id into v_id;
  end if;

  return v_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_notifications_clear(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid := public.jl_player_id(p_token);
  changed integer := 0;
begin
  update public.player_notifications
  set dismissed_at=now(), read_at=coalesce(read_at,now())
  where player_id=me and dismissed_at is null;
  get diagnostics changed=row_count;
  return jsonb_build_object('ok',true,'changed',changed);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_notifications_feed(p_token text, p_limit integer DEFAULT 80)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid := public.jl_player_id(p_token);
  lim integer := greatest(1,least(coalesce(p_limit,80),100));
  rows jsonb;
begin
  update public.player_sessions
  set last_seen_at=now()
  where token_hash=public.jl_token_hash(p_token)
    and expires_at>now();

  select coalesce(jsonb_agg(x order by x."createdAt" desc),'[]'::jsonb)
  into rows
  from (
    select
      coalesce(n.source_key,'server:'||n.id::text) as id,
      n.id as "serverId",
      n.kind as type,
      n.title,
      n.message,
      n.href,
      n.created_at as "createdAt",
      (n.read_at is not null) as read,
      true as "serverBacked"
    from public.player_notifications n
    where n.player_id=me
      and n.dismissed_at is null
    order by n.created_at desc
    limit lim
  ) x;

  return rows;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_notifications_mark_read(p_token text, p_notification_id bigint DEFAULT NULL::bigint, p_source_key text DEFAULT NULL::text, p_all boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid := public.jl_player_id(p_token);
  changed integer := 0;
begin
  if coalesce(p_all,false) then
    update public.player_notifications
    set read_at=coalesce(read_at,now())
    where player_id=me and dismissed_at is null and read_at is null;
    get diagnostics changed=row_count;
  elsif p_notification_id is not null then
    update public.player_notifications
    set read_at=coalesce(read_at,now())
    where player_id=me and id=p_notification_id and dismissed_at is null;
    get diagnostics changed=row_count;
  elsif nullif(trim(coalesce(p_source_key,'')),'') is not null then
    update public.player_notifications
    set read_at=coalesce(read_at,now())
    where player_id=me and source_key=p_source_key and dismissed_at is null;
    get diagnostics changed=row_count;
  end if;
  return jsonb_build_object('ok',true,'changed',changed);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_notify_deposit_status()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.status='pending' then return new; end if;
  if tg_op='UPDATE' and old.status is not distinct from new.status then return new; end if;

  perform public.jl_notification_create(
    new.player_id,
    'finance',
    case when new.status='approved' then 'Depósito aprovado' else 'Depósito rejeitado' end,
    new.amount||' MZN · '||
      case when new.status='approved'
        then 'O valor foi creditado no seu saldo.'
        else 'O pedido de depósito não foi aprovado.'
      end,
    './index.html#depositPanel',
    'deposit-status:'||new.id::text||':'||new.status
  );
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_notify_ludo_invite()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r public.ludo_rooms%rowtype;
  host_name text;
  host_code text;
begin
  if new.status<>'pending' then return new; end if;
  select * into r from public.ludo_rooms where id=new.room_id;
  select name into host_name from public.players where id=new.invited_by;
  host_code:=public.jl_ludo_display_code(new.invited_by);

  perform public.jl_notification_create(
    new.target_player_id,
    'ludo-invite',
    'Convite de '||coalesce(host_name,'jogador'),
    coalesce(r.code,'Ludo')||' · '||coalesce(r.player_count,0)||' jogadores · '||
      coalesce(r.mode,'solo')||' · '||coalesce(r.bet_amount,0)||' MZN',
    './ludo.html#notificationCenter',
    'ludo-invite:'||new.id::text
  );
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_notify_ludo_payout()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  room_code text;
  net_key text;
begin
  if coalesce(new.net_amount,0)<=0 then return new; end if;
  select code into room_code from public.ludo_rooms where id=new.room_id;
  net_key:=regexp_replace(
    regexp_replace(new.net_amount::text,'(\.[0-9]*?)0+$','\1'),
    '\.$',''
  );

  perform public.jl_notification_create(
    new.player_id,
    'win',
    'Vitória no Ludo',
    'Você ganhou '||new.net_amount||' MZN na partida '||coalesce(room_code,new.room_id::text)||'.',
    './ludo.html#resultPanel',
    'ludo-win:'||new.room_id::text||':'||new.player_id::text||':'||net_key
  );
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_notify_number_win()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if coalesce(new.won,false)
     and coalesce(new.payout,0)>0
     and (tg_op='INSERT' or not coalesce(old.won,false) or old.payout is distinct from new.payout) then
    perform public.jl_notification_create(
      new.player_id,
      'win',
      'Parabéns! Você ganhou',
      'Você ganhou '||new.payout||' MZN no Número Lendário.',
      './index.html#playerArea',
      'number-win:'||new.id::text
    );
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_notify_pair_win()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if coalesce(new.won,false)
     and coalesce(new.payout,0)>0
     and (tg_op='INSERT' or not coalesce(old.won,false) or old.payout is distinct from new.payout) then
    perform public.jl_notification_create(
      new.player_id,
      'win',
      'Parabéns! Você ganhou',
      'Você ganhou '||new.payout||' MZN na Dupla Lendária.',
      './index.html#playerArea',
      'pair-win:'||new.id::text
    );
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_notify_support_reply()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.sender='admin' then
    perform public.jl_notification_create(
      new.player_id,
      'support',
      'Nova resposta da Linha de Cliente',
      left(new.message,260),
      './index.html?open=support#playerArea',
      'support:'||new.id::text
    );
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_notify_withdrawal_status()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.status='pending' then return new; end if;
  if tg_op='UPDATE' and old.status is not distinct from new.status then return new; end if;

  perform public.jl_notification_create(
    new.player_id,
    'finance',
    case when new.status='approved' then 'Saque aprovado' else 'Saque rejeitado' end,
    new.amount||' MZN · '||
      case when new.status='approved'
        then 'O saque foi aprovado.'
        else coalesce(nullif(new.reason,''),'O pedido de saque não foi aprovado.')
      end,
    './index.html#withdrawPanel',
    'withdraw-status:'||new.id::text||':'||new.status
  );
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_open_next_game_round(p_game_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_item public.draw_schedule%rowtype;
  v_round public.game_rounds%rowtype;
  v_settings public.game_settings%rowtype;
begin
  select * into v_settings from public.game_settings where game_type=p_game_type;
  if v_settings.game_type is null then raise exception 'Jogo inválido.'; end if;
  if not v_settings.enabled then return jsonb_build_object('opened',false,'reason','disabled'); end if;

  if exists (
    select 1 from public.game_rounds
    where game_type=p_game_type and status in ('open','locked','closed','drawn')
  ) then
    return jsonb_build_object('opened',false,'reason','active_round');
  end if;

  update public.draw_schedule
  set status='missed', updated_at=now()
  where game_type=p_game_type and status='pending'
    and draw_at <= now() + make_interval(secs => v_settings.lock_seconds);

  select * into v_item
  from public.draw_schedule
  where game_type=p_game_type and status='pending'
  order by draw_at
  limit 1
  for update skip locked;

  if v_item.id is null then return jsonb_build_object('opened',false,'reason','no_pending_schedule'); end if;

  insert into public.game_rounds(game_type,status,closes_at,draw_at,schedule_id)
  values(p_game_type,'open',v_item.draw_at-make_interval(secs => v_settings.lock_seconds),v_item.draw_at,v_item.id)
  returning * into v_round;

  update public.draw_schedule
  set status='active',round_id=v_round.id,updated_at=now()
  where id=v_item.id;

  return jsonb_build_object(
    'opened',true,'game_type',p_game_type,'round_no',v_round.round_no,
    'closes_at',v_round.closes_at,'draw_at',v_round.draw_at,'schedule_id',v_item.id
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_open_next_scheduled_round()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return public.jl_open_next_game_round('number');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_persist_ludo_invite()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if new.status='pending' then new.expires_at:='infinity'::timestamptz; end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_persist_ludo_room_waiting()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if new.status='negotiating' then
    new.action_deadline:=null;
  end if;
  if new.is_public and new.status in ('waiting','negotiating') then
    new.public_challenge_expires_at:='infinity'::timestamptz;
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_phone(p_phone text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  with d as (
    select regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g') as digits
  )
  select case
    when digits ~ '^00258[0-9]{9}$' then substr(digits, 6)
    when digits ~ '^258[0-9]{9}$' then substr(digits, 4)
    else digits
  end
  from d;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_place_bet_idempotent(p_token text, p_selected_number integer, p_amount numeric, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_player uuid:=public.jl_player_id(p_token);
  v_hash text; v_claim jsonb; v_response jsonb;
begin
  v_hash:=encode(extensions.digest(jsonb_build_object(
    'number',p_selected_number,'amount',coalesce(p_amount,0)
  )::text,'sha256'),'hex');

  v_claim:=public.jl_financial_idempotency_claim(
    'player',v_player,'number_bet',p_idempotency_key,v_hash
  );
  if not (v_claim->>'claimed')::boolean then return v_claim->'response'; end if;

  v_response:=public.jl_place_bet(p_token,p_selected_number,p_amount);
  perform public.jl_financial_idempotency_complete(
    'player',v_player,'number_bet',p_idempotency_key,v_response
  );
  return v_response;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_place_bet(p_token text, p_selected_number integer, p_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_player public.players%rowtype;
  v_round public.game_rounds%rowtype;
  v_settings public.game_settings%rowtype;
  v_bet_id uuid;
  v_total_after numeric;
  v_min_after numeric;
  v_bonus_available numeric:=0;
  v_bonus_used numeric:=0;
  v_cash_used numeric:=0;
  v_consumed numeric:=0;
  v_deposit_cleared numeric:=0;
begin
  select * into v_settings from public.game_settings where game_type='number';
  if not v_settings.enabled then raise exception 'Número Lendário está temporariamente desativado.'; end if;
  if p_selected_number<0 or p_selected_number>10 then raise exception 'Escolha um número de 0 a 10.'; end if;
  if p_amount is null or p_amount<>trunc(p_amount) or p_amount<v_settings.min_bet or p_amount>v_settings.max_bet then
    raise exception 'A aposta deve ser um valor inteiro entre % e % MZN.',v_settings.min_bet,v_settings.max_bet;
  end if;

  select * into v_round from public.game_rounds
  where game_type='number' and status='open' and closes_at>now()
  order by opened_at desc limit 1 for update;
  if v_round.id is null then raise exception 'As apostas do Número Lendário estão fechadas neste momento.'; end if;

  select * into v_player from public.players where id=v_player_id for update;
  if v_player.blocked then raise exception 'Esta conta está bloqueada.'; end if;

  v_bonus_available:=public.jl_bonus_available(v_player_id,'number');
  if v_player.balance+v_bonus_available<p_amount then
    raise exception 'Saldo e bónus insuficientes para esta aposta.';
  end if;

  v_bonus_used:=least(p_amount,v_bonus_available);
  v_cash_used:=p_amount-v_bonus_used;

  select coalesce(sum(amount),0)+p_amount into v_total_after
  from public.bets where round_id=v_round.id;

  select min(exposure) into v_min_after
  from (
    select n,coalesce(sum(b.amount),0)+case when n=p_selected_number then p_amount else 0 end exposure
    from generate_series(0,10) n
    left join public.bets b on b.round_id=v_round.id and b.selected_number=n
    group by n
  ) x;

  if v_min_after*v_settings.multiplier>=v_total_after then
    raise exception 'Esta aposta atingiria o limite de segurança da rodada. Escolha outro número ou aguarde a próxima rodada.';
  end if;

  insert into public.bets(round_id,player_id,selected_number,amount,cash_amount,bonus_amount)
  values(v_round.id,v_player_id,p_selected_number,p_amount,v_cash_used,v_bonus_used)
  returning id into v_bet_id;

  if v_bonus_used>0 then
    v_consumed:=public.jl_consume_bonus(v_player_id,'number',v_bonus_used,v_bet_id);
    if v_consumed<>v_bonus_used then raise exception 'Não foi possível reservar o bónus desta aposta.'; end if;
  end if;

  if v_cash_used>0 then
    update public.players set balance=balance-v_cash_used,updated_at=now() where id=v_player_id;
    v_deposit_cleared:=public.jl_apply_cash_wager(v_player_id,v_cash_used,'number_bet',v_bet_id);

    insert into public.transactions(player_id,kind,amount,status,reference_id,note)
    values(v_player_id,'bet',-v_cash_used,'completed',v_bet_id,
      'Aposta no Número Lendário · '||v_bonus_used||' MZN de bónus · '||
      v_deposit_cleared||' MZN de depósito liberado');
  end if;

  return jsonb_build_object(
    'ok',true,'bet_id',v_bet_id,'round_no',v_round.round_no,
    'selected_number',p_selected_number,'amount',p_amount,
    'cash_used',v_cash_used,'bonus_used',v_bonus_used,
    'deposit_wager_cleared',v_deposit_cleared,
    'balance',v_player.balance-v_cash_used,
    'deposit_locked',public.jl_deposit_wager_locked(v_player_id),
    'bonus_remaining',public.jl_bonus_available(v_player_id,'number')
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_place_pair_bet_idempotent(p_token text, p_number_a integer, p_number_b integer, p_amount numeric, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_player uuid:=public.jl_player_id(p_token);
  v_a integer:=least(p_number_a,p_number_b);
  v_b integer:=greatest(p_number_a,p_number_b);
  v_hash text; v_claim jsonb; v_response jsonb;
begin
  v_hash:=encode(extensions.digest(jsonb_build_object(
    'number_a',v_a,'number_b',v_b,'amount',coalesce(p_amount,0)
  )::text,'sha256'),'hex');

  v_claim:=public.jl_financial_idempotency_claim(
    'player',v_player,'pair_bet',p_idempotency_key,v_hash
  );
  if not (v_claim->>'claimed')::boolean then return v_claim->'response'; end if;

  v_response:=public.jl_place_pair_bet(p_token,p_number_a,p_number_b,p_amount);
  perform public.jl_financial_idempotency_complete(
    'player',v_player,'pair_bet',p_idempotency_key,v_response
  );
  return v_response;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_place_pair_bet(p_token text, p_number_a integer, p_number_b integer, p_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_player public.players%rowtype;
  v_round public.game_rounds%rowtype;
  v_settings public.game_settings%rowtype;
  v_bet_id uuid;
  v_a integer;
  v_b integer;
  v_total_after numeric;
  v_min_after numeric;
  v_bonus_available numeric:=0;
  v_bonus_used numeric:=0;
  v_cash_used numeric:=0;
  v_consumed numeric:=0;
  v_deposit_cleared numeric:=0;
begin
  select * into v_settings from public.game_settings where game_type='pair';
  if not v_settings.enabled then raise exception 'Dupla Lendária está temporariamente desativada.'; end if;
  if p_number_a is null or p_number_b is null then raise exception 'Escolha dois números.'; end if;
  if p_number_a<0 or p_number_a>10 or p_number_b<0 or p_number_b>10 then raise exception 'Escolha dois números entre 0 e 10.'; end if;
  if p_number_a=p_number_b then raise exception 'Escolha dois números diferentes.'; end if;

  v_a:=least(p_number_a,p_number_b);
  v_b:=greatest(p_number_a,p_number_b);

  if p_amount is null or p_amount<>trunc(p_amount) or p_amount<v_settings.min_bet or p_amount>v_settings.max_bet then
    raise exception 'A aposta deve ser um valor inteiro entre % e % MZN.',v_settings.min_bet,v_settings.max_bet;
  end if;

  select * into v_round from public.game_rounds
  where game_type='pair' and status='open' and closes_at>now()
  order by opened_at desc limit 1 for update;
  if v_round.id is null then raise exception 'As apostas da Dupla Lendária estão fechadas neste momento.'; end if;

  select * into v_player from public.players where id=v_player_id for update;
  if v_player.blocked then raise exception 'Esta conta está bloqueada.'; end if;

  v_bonus_available:=public.jl_bonus_available(v_player_id,'pair');
  if v_player.balance+v_bonus_available<p_amount then
    raise exception 'Saldo e bónus insuficientes para esta aposta.';
  end if;

  v_bonus_used:=least(p_amount,v_bonus_available);
  v_cash_used:=p_amount-v_bonus_used;

  select coalesce(sum(amount),0)+p_amount into v_total_after
  from public.pair_bets where round_id=v_round.id;

  select min(exposure) into v_min_after
  from (
    select a,b,coalesce(sum(pb.amount),0)+case when a=v_a and b=v_b then p_amount else 0 end exposure
    from generate_series(0,10) a
    cross join generate_series(0,10) b
    left join public.pair_bets pb on pb.round_id=v_round.id and pb.number_a=a and pb.number_b=b
    where a<b
    group by a,b
  ) x;

  if v_min_after*v_settings.multiplier>=v_total_after then
    raise exception 'Esta aposta atingiria o limite de segurança da rodada. Escolha outra combinação ou aguarde a próxima rodada.';
  end if;

  insert into public.pair_bets(round_id,player_id,number_a,number_b,amount,cash_amount,bonus_amount)
  values(v_round.id,v_player_id,v_a,v_b,p_amount,v_cash_used,v_bonus_used)
  returning id into v_bet_id;

  if v_bonus_used>0 then
    v_consumed:=public.jl_consume_bonus(v_player_id,'pair',v_bonus_used,v_bet_id);
    if v_consumed<>v_bonus_used then raise exception 'Não foi possível reservar o bónus desta aposta.'; end if;
  end if;

  if v_cash_used>0 then
    update public.players set balance=balance-v_cash_used,updated_at=now() where id=v_player_id;
    v_deposit_cleared:=public.jl_apply_cash_wager(v_player_id,v_cash_used,'pair_bet',v_bet_id);

    insert into public.transactions(player_id,kind,amount,status,reference_id,note)
    values(v_player_id,'bet',-v_cash_used,'completed',v_bet_id,
      'Aposta Dupla Lendária '||v_a||'+'||v_b||' · '||v_bonus_used||
      ' MZN de bónus · '||v_deposit_cleared||' MZN de depósito liberado');
  end if;

  return jsonb_build_object(
    'ok',true,'bet_id',v_bet_id,'round_no',v_round.round_no,
    'number_a',v_a,'number_b',v_b,'amount',p_amount,
    'cash_used',v_cash_used,'bonus_used',v_bonus_used,
    'deposit_wager_cleared',v_deposit_cleared,
    'balance',v_player.balance-v_cash_used,
    'deposit_locked',public.jl_deposit_wager_locked(v_player_id),
    'bonus_remaining',public.jl_bonus_available(v_player_id,'pair')
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_player_bet_summary(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid := public.jl_player_id(p_token);
  result jsonb;
begin
  with all_bets as (
    select amount, won, payout from public.bets where player_id=me
    union all
    select amount, won, payout from public.pair_bets where player_id=me
  )
  select jsonb_build_object(
    'total_count', count(*),
    'total_amount', coalesce(sum(amount),0),
    'pending_count', count(*) filter (where won is null),
    'pending_amount', coalesce(sum(amount) filter (where won is null),0),
    'loss_count', count(*) filter (where won is false),
    'loss_amount', coalesce(sum(amount) filter (where won is false),0),
    'win_count', count(*) filter (where won is true),
    'win_stake_amount', coalesce(sum(amount) filter (where won is true),0),
    'win_payout_amount', coalesce(sum(payout) filter (where won is true),0),
    'net_result', coalesce(sum(case when won is true then coalesce(payout,0)-amount when won is false then -amount else 0 end),0)
  ) into result
  from all_bets;
  return result;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_player_id(p_token text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_id uuid;
  v_session_id uuid;
begin
  select id,player_id
  into v_session_id,v_id
  from public.player_sessions
  where token_hash=public.jl_token_hash(p_token)
    and expires_at>now()
  limit 1;

  if v_id is null then
    raise exception 'Sessão do jogador inválida ou expirada.';
  end if;

  update public.player_sessions
  set last_seen_at=now()
  where id=v_session_id
    and last_seen_at<now()-interval '5 minutes';

  return v_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_player_revoke_all_sessions(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid:=public.jl_player_id(p_token);
  changed integer:=0;
begin
  delete from public.player_sessions
  where player_id=me;
  get diagnostics changed=row_count;

  return jsonb_build_object('ok',true,'revoked',changed);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_player_revoke_other_sessions(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid:=public.jl_player_id(p_token);
  current_hash text:=public.jl_token_hash(p_token);
  changed integer:=0;
begin
  delete from public.player_sessions
  where player_id=me
    and token_hash<>current_hash;
  get diagnostics changed=row_count;

  return jsonb_build_object('ok',true,'revoked',changed);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_player_revoke_session(p_token text, p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid:=public.jl_player_id(p_token);
  current_hash text:=public.jl_token_hash(p_token);
  removed_hash text;
begin
  delete from public.player_sessions
  where id=p_session_id
    and player_id=me
  returning token_hash into removed_hash;

  if removed_hash is null then
    raise exception 'Sessão não encontrada.';
  end if;

  return jsonb_build_object(
    'ok',true,
    'current_ended',removed_hash=current_hash
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_player_sessions(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid:=public.jl_player_id(p_token);
  current_hash text:=public.jl_token_hash(p_token);
  rows jsonb;
begin
  select coalesce(jsonb_agg(x order by x.is_current desc,x.last_seen_at desc),'[]'::jsonb)
  into rows
  from (
    select
      s.id as session_id,
      (s.token_hash=current_hash) as is_current,
      s.created_at,
      s.last_seen_at,
      s.expires_at,
      s.rotated_at,
      coalesce(s.user_agent,'Dispositivo não identificado') as user_agent
    from public.player_sessions s
    where s.player_id=me
      and s.expires_at>now()
  ) x;

  return rows;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_player_state(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_player public.players%rowtype;
  v_public jsonb;
  v_bets jsonb;
  v_pair_bets jsonb;
  v_deposits jsonb;
  v_withdrawals jsonb;
  v_bonus_total numeric;
  v_bonus_number numeric;
  v_bonus_pair numeric;
  v_bonus_grants jsonb;
  v_deposit_locked numeric;
  v_withdrawable numeric;
begin
  select * into v_player from public.players where id=v_player_id;
  select public.jl_public_state() into v_public;

  v_deposit_locked:=public.jl_deposit_wager_locked(v_player_id);
  v_withdrawable:=greatest(0,v_player.balance-v_deposit_locked);

  select
    coalesce(sum(remaining_amount) filter(where status='active'),0),
    coalesce(sum(remaining_amount) filter(where status='active' and game_scope in ('number','both')),0),
    coalesce(sum(remaining_amount) filter(where status='active' and game_scope in ('pair','both')),0)
  into v_bonus_total,v_bonus_number,v_bonus_pair
  from public.bonus_grants where player_id=v_player_id;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_bonus_grants
  from (
    select id,game_scope,bonus_type,original_amount,remaining_amount,played_amount,status,note,created_at
    from public.bonus_grants
    where player_id=v_player_id
    order by created_at desc
    limit 30
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_bets
  from (
    select b.id,b.selected_number,b.amount,b.cash_amount,b.bonus_amount,b.won,b.payout,b.created_at,r.round_no,
      case when r.status='published' then r.drawn_number else null end drawn_number,r.status round_status
    from public.bets b join public.game_rounds r on r.id=b.round_id
    where b.player_id=v_player_id order by b.created_at desc limit 30
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_pair_bets
  from (
    select pb.id,pb.number_a,pb.number_b,pb.amount,pb.cash_amount,pb.bonus_amount,pb.won,pb.payout,pb.created_at,r.round_no,
      case when r.status='published' then r.pair_drawn_a else null end pair_drawn_a,
      case when r.status='published' then r.pair_drawn_b else null end pair_drawn_b,
      r.status round_status
    from public.pair_bets pb join public.game_rounds r on r.id=pb.round_id
    where pb.player_id=v_player_id order by pb.created_at desc limit 30
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_deposits
  from (
    select d.id,d.amount,d.note,d.status,d.created_at,d.reviewed_at,
           coalesce(w.remaining_amount,0) wager_remaining
    from public.deposit_requests d
    left join public.deposit_wager_requirements w on w.deposit_request_id=d.id
    where d.player_id=v_player_id
    order by d.created_at desc
    limit 20
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_withdrawals
  from (
    select id,amount,status,reason,created_at,reviewed_at
    from public.withdrawal_requests
    where player_id=v_player_id
    order by created_at desc
    limit 20
  ) x;

  return v_public || jsonb_build_object(
    'player',jsonb_build_object(
      'id',v_player.id,
      'name',v_player.name,
      'phone',v_player.phone,
      'balance',v_player.balance,
      'withdrawable_balance',v_withdrawable,
      'deposit_locked',v_deposit_locked,
      'bonus_balance',v_bonus_total,
      'blocked',v_player.blocked
    ),
    'deposit_wager',jsonb_build_object(
      'locked',v_deposit_locked,
      'withdrawable',v_withdrawable
    ),
    'bonus',jsonb_build_object(
      'total',v_bonus_total,'number',v_bonus_number,'pair',v_bonus_pair,'grants',v_bonus_grants
    ),
    'bets',v_bets,
    'pair_bets',v_pair_bets,
    'deposits',v_deposits,
    'withdrawals',v_withdrawals
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_process_game_engine_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_need_work boolean:=false;
begin
  select exists(
    select 1
    from public.game_rounds
    where status in ('open','locked','closed')
      and (
        (status='open' and closes_at<=now())
        or draw_at<=now()
      )
  )
  or exists(
    select 1
    from public.draw_schedule ds
    join public.game_settings gs
      on gs.game_type=ds.game_type
     and gs.enabled
    where ds.status='pending'
      and not exists(
        select 1
        from public.game_rounds gr
        where gr.game_type=ds.game_type
          and gr.status in ('open','locked','closed','drawn')
      )
  )
  into v_need_work;

  if not v_need_work then
    return jsonb_build_object('idle',true,'processed_at',now());
  end if;

  return public.jl_process_game_engine();
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_process_game_engine()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_number jsonb; v_pair jsonb;
begin
  v_number := public.jl_process_game('number');
  v_pair := public.jl_process_game('pair');
  return jsonb_build_object('number',v_number,'pair',v_pair,'processed_at',now());
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_process_game(p_game_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_locked integer := 0;
  v_drawn integer := 0;
  v_opened jsonb;
  v_lock_key bigint;
begin
  if p_game_type not in ('number','pair') then raise exception 'Jogo inválido.'; end if;
  v_lock_key := case when p_game_type='number' then 740112337 else 740112338 end;

  if not pg_try_advisory_xact_lock(v_lock_key) then
    return jsonb_build_object('busy',true,'game_type',p_game_type,'processed_at',now());
  end if;

  update public.game_rounds
  set status='locked',closed_at=coalesce(closed_at,closes_at)
  where game_type=p_game_type and status='open'
    and closes_at <= now() and (drawn_number is null and pair_drawn_a is null);
  get diagnostics v_locked=row_count;

  v_drawn := public.jl_finalize_game_due_rounds(p_game_type);
  v_opened := public.jl_open_next_game_round(p_game_type);

  return jsonb_build_object(
    'game_type',p_game_type,'locked',v_locked,'drawn',v_drawn,
    'next',v_opened,'processed_at',now()
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_public_state()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_number jsonb; v_pair jsonb;
begin
  perform public.jl_process_game_engine();
  v_number := public.jl_game_public_state('number');
  v_pair := public.jl_game_public_state('pair');

  return jsonb_build_object(
    'server_time',now(),
    'games',jsonb_build_object('number',v_number,'pair',v_pair),
    'current_round',v_number->'current_round',
    'last_result',v_number->'last_result'
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_push_after_notification_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'vault', 'extensions'
AS $function$
declare
  dispatch_key text;
begin
  if not exists(
    select 1 from public.player_push_subscriptions s
    where s.player_id=new.player_id and s.disabled_at is null
  ) then
    return new;
  end if;

  select decrypted_secret into dispatch_key
  from vault.decrypted_secrets
  where name='jl_push_dispatch_secret'
  order by created_at desc
  limit 1;

  if coalesce(dispatch_key,'')='' then
    return new;
  end if;

  perform net.http_post(
    url:='https://bxndjyzghgrmkelshtdp.supabase.co/functions/v1/jogos-push/dispatch',
    headers:=jsonb_build_object(
      'Content-Type','application/json',
      'x-jl-push-secret',dispatch_key
    ),
    body:=jsonb_build_object('notification_id',new.id),
    timeout_milliseconds:=5000
  );

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_push_dispatch_secret()
 RETURNS text
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'vault'
AS $function$
  select decrypted_secret
  from vault.decrypted_secrets
  where name='jl_push_dispatch_secret'
  order by created_at desc
  limit 1;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_push_mark_delivery(p_notification_id bigint, p_sent_count integer DEFAULT 0, p_invalid_endpoints text[] DEFAULT ARRAY[]::text[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update public.player_notifications
  set push_attempted_at=now(),
      push_sent_at=case when coalesce(p_sent_count,0)>0 then now() else push_sent_at end
  where id=p_notification_id;

  if coalesce(array_length(p_invalid_endpoints,1),0)>0 then
    update public.player_push_subscriptions
    set disabled_at=now(),updated_at=now()
    where endpoint=any(p_invalid_endpoints);
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_push_service_bundle(p_notification_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'vault'
AS $function$
declare
  v_public text;
  v_private text;
  v_notice jsonb;
  v_subs jsonb;
begin
  select decrypted_secret into v_public
  from vault.decrypted_secrets
  where name='jl_web_push_vapid_public'
  order by created_at desc
  limit 1;

  select decrypted_secret into v_private
  from vault.decrypted_secrets
  where name='jl_web_push_vapid_private'
  order by created_at desc
  limit 1;

  select jsonb_build_object(
    'id',coalesce(n.source_key,'server:'||n.id::text),
    'serverId',n.id,
    'playerId',n.player_id,
    'title',n.title,
    'message',n.message,
    'href',n.href,
    'type',n.kind,
    'createdAt',n.created_at
  )
  into v_notice
  from public.player_notifications n
  where n.id=p_notification_id and n.dismissed_at is null;

  if v_notice is null then
    return null;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'endpoint',s.endpoint,
    'keys',jsonb_build_object('p256dh',s.p256dh,'auth',s.auth)
  )),'[]'::jsonb)
  into v_subs
  from public.player_push_subscriptions s
  where s.player_id=(v_notice->>'playerId')::uuid
    and s.disabled_at is null;

  return jsonb_build_object(
    'vapid_public',v_public,
    'vapid_private',v_private,
    'notification',v_notice,
    'subscriptions',v_subs
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_push_subscribe(p_token text, p_endpoint text, p_p256dh text, p_auth text, p_user_agent text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid := public.jl_player_id(p_token);
  v_id uuid;
  v_endpoint text := left(coalesce(p_endpoint,''),2048);
  v_p256dh text := left(coalesce(p_p256dh,''),500);
  v_auth text := left(coalesce(p_auth,''),500);
  v_user_agent text := left(coalesce(p_user_agent,''),300);
begin
  if v_endpoint='' or length(v_endpoint) not between 20 and 2048 or v_endpoint !~ '^https://' then
    raise exception 'Subscrição push inválida.';
  end if;

  if length(v_p256dh)<20 or length(v_auth)<8 then
    raise exception 'Chaves push inválidas.';
  end if;

  select s.id
  into v_id
  from public.player_push_subscriptions s
  where s.endpoint=v_endpoint
    and s.player_id=me
    and s.p256dh=v_p256dh
    and s.auth=v_auth
    and coalesce(s.user_agent,'')=v_user_agent
    and s.disabled_at is null
  limit 1;

  if v_id is not null then
    return jsonb_build_object(
      'ok',true,
      'subscription_id',v_id,
      'reused',true
    );
  end if;

  insert into public.player_push_subscriptions(
    player_id,endpoint,p256dh,auth,user_agent,updated_at,disabled_at
  )
  values(
    me,v_endpoint,v_p256dh,v_auth,v_user_agent,now(),null
  )
  on conflict(endpoint) do update set
    player_id=excluded.player_id,
    p256dh=excluded.p256dh,
    auth=excluded.auth,
    user_agent=excluded.user_agent,
    updated_at=now(),
    disabled_at=null
  returning id into v_id;

  return jsonb_build_object(
    'ok',true,
    'subscription_id',v_id,
    'reused',false
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_push_unsubscribe(p_token text, p_endpoint text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid := public.jl_player_id(p_token);
  changed integer := 0;
begin
  update public.player_push_subscriptions
  set disabled_at=now(),updated_at=now()
  where player_id=me and endpoint=p_endpoint and disabled_at is null;
  get diagnostics changed=row_count;
  return jsonb_build_object('ok',true,'changed',changed);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_random_index(p_count integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  b integer;
  limit_byte integer;
begin
  if p_count is null or p_count < 1 or p_count > 256 then
    raise exception 'Quantidade inválida para sorteio.';
  end if;

  limit_byte := 256 - (256 % p_count);
  loop
    b := get_byte(extensions.gen_random_bytes(1), 0);
    if b < limit_byte then
      return (b % p_count) + 1;
    end if;
  end loop;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_register_player(p_name text, p_phone text, p_pin text, p_invite_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.jl_register_player(p_name text, p_phone text, p_pin text)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
  select public.jl_register_player(p_name,p_phone,p_pin,null::text);
$function$
;

CREATE OR REPLACE FUNCTION public.jl_request_deposit_idempotent(p_token text, p_amount numeric, p_note text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_player uuid:=public.jl_player_id(p_token);
  v_hash text; v_claim jsonb; v_response jsonb;
begin
  v_hash:=encode(extensions.digest(jsonb_build_object(
    'amount',round(coalesce(p_amount,0),2),
    'note',left(trim(coalesce(p_note,'')),160)
  )::text,'sha256'),'hex');

  v_claim:=public.jl_financial_idempotency_claim(
    'player',v_player,'deposit_request',p_idempotency_key,v_hash
  );
  if not (v_claim->>'claimed')::boolean then return v_claim->'response'; end if;

  v_response:=public.jl_request_deposit(p_token,p_amount,p_note);
  perform public.jl_financial_idempotency_complete(
    'player',v_player,'deposit_request',p_idempotency_key,v_response
  );
  return v_response;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_request_deposit(p_token text, p_amount numeric, p_note text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_player_id uuid := public.jl_player_id(p_token);
declare v_id uuid;
begin
  if p_amount is null or p_amount < 1 or p_amount > 1000000 then raise exception 'Valor de depósito inválido.'; end if;
  insert into public.deposit_requests(player_id,amount,note)
  values(v_player_id,round(p_amount,2),left(trim(coalesce(p_note,'')),160)) returning id into v_id;
  return jsonb_build_object('ok',true,'request_id',v_id,'status','pending','message','Pedido de depósito enviado e aguardando confirmação do administrador.');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_request_pin_recovery(p_phone text, p_email text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_phone text:=public.jl_phone(p_phone);
  v_email text:=nullif(lower(trim(coalesce(p_email,''))),'');
  v_player public.players%rowtype;
  v_message text:='Pedido enviado ao administrador para confirmação.';
  v_requests_24h integer:=0;
begin
  if char_length(v_phone)<8 or char_length(v_phone)>15 then
    return jsonb_build_object('ok',false,'message','Informe um telefone válido.');
  end if;

  if v_email is not null
     and v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
    return jsonb_build_object('ok',false,'message','Informe um e-mail válido ou deixe o campo vazio.');
  end if;

  -- Resposta neutra: o limite não revela se a conta existe.
  select count(*)::integer
  into v_requests_24h
  from public.pin_recovery_requests
  where phone=v_phone
    and requested_at>=now()-interval '24 hours';

  if v_requests_24h>=3 then
    return jsonb_build_object('ok',true,'message',v_message);
  end if;

  select * into v_player
  from public.players
  where public.jl_phone(phone)=v_phone
    and deleted_at is null
  limit 1;

  if v_player.id is not null then
    if exists(
      select 1 from public.pin_recovery_requests
      where player_id=v_player.id
        and status in ('pending_admin','sending','code_sent')
    ) then
      return jsonb_build_object('ok',true,'message',v_message);
    end if;

    begin
      insert into public.pin_recovery_requests(player_id,phone,recovery_email,status)
      values(v_player.id,v_phone,v_email,'pending_admin');
    exception when unique_violation then
      null;
    end;
  else
    if exists(
      select 1 from public.pin_recovery_requests
      where player_id is null
        and phone=v_phone
        and status in ('pending_admin','sending','code_sent')
    ) then
      return jsonb_build_object('ok',true,'message',v_message);
    end if;

    begin
      insert into public.pin_recovery_requests(player_id,phone,recovery_email,status)
      values(null,v_phone,v_email,'pending_admin');
    exception when unique_violation then
      null;
    end;
  end if;

  return jsonb_build_object('ok',true,'message',v_message);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_request_withdrawal_idempotent(p_token text, p_amount numeric, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_player uuid:=public.jl_player_id(p_token);
  v_hash text; v_claim jsonb; v_response jsonb;
begin
  v_hash:=encode(extensions.digest(
    jsonb_build_object('amount',round(coalesce(p_amount,0),2))::text,'sha256'
  ),'hex');

  v_claim:=public.jl_financial_idempotency_claim(
    'player',v_player,'withdrawal_request',p_idempotency_key,v_hash
  );
  if not (v_claim->>'claimed')::boolean then return v_claim->'response'; end if;

  v_response:=public.jl_request_withdrawal(p_token,p_amount);
  perform public.jl_financial_idempotency_complete(
    'player',v_player,'withdrawal_request',p_idempotency_key,v_response
  );
  return v_response;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_request_withdrawal(p_token text, p_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_player public.players%rowtype;
  v_id uuid;
  v_locked numeric:=0;
  v_withdrawable numeric:=0;
begin
  if p_amount is null or p_amount<1 or p_amount>1000000 then
    raise exception 'Valor de saque inválido.';
  end if;

  select *
  into v_player
  from public.players
  where id=v_player_id
    and deleted_at is null
  for update;

  if v_player.id is null then
    raise exception 'Conta indisponível.';
  end if;

  v_locked:=public.jl_deposit_wager_locked(v_player_id);
  v_withdrawable:=greatest(0,v_player.balance-v_locked);

  if p_amount>v_withdrawable then
    insert into public.withdrawal_requests(
      player_id,amount,status,reason,reviewed_at
    )
    values(
      v_player_id,
      round(p_amount,2),
      'rejected',
      case
        when v_player.balance<p_amount then 'Saldo insuficiente'
        else 'Depósito ainda não foi jogado'
      end,
      now()
    )
    returning id into v_id;

    return jsonb_build_object(
      'ok',false,
      'request_id',v_id,
      'status','rejected',
      'message',
        case
          when v_player.balance<p_amount then 'Saque rejeitado automaticamente: saldo insuficiente.'
          else 'Saque bloqueado: parte do saldo vem de depósito que ainda precisa ser jogado.'
        end,
      'balance',v_player.balance,
      'deposit_locked',v_locked,
      'withdrawable_balance',v_withdrawable
    );
  end if;

  update public.players
  set balance=balance-round(p_amount,2),
      updated_at=now()
  where id=v_player_id;

  insert into public.withdrawal_requests(player_id,amount,status)
  values(v_player_id,round(p_amount,2),'pending')
  returning id into v_id;

  insert into public.transactions(
    player_id,kind,amount,status,reference_id,note
  )
  values(
    v_player_id,
    'withdrawal',
    -round(p_amount,2),
    'pending',
    v_id,
    'Valor reservado para saque'
  );

  return jsonb_build_object(
    'ok',true,
    'request_id',v_id,
    'status','pending',
    'message','Pedido de saque enviado para autorização.',
    'balance',v_player.balance-round(p_amount,2),
    'deposit_locked',v_locked,
    'withdrawable_balance',v_withdrawable-round(p_amount,2)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_require_admin_elevated(p_token text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_admin uuid:=public.jl_admin_account_id(p_token);
  v_ok boolean;
begin
  if v_admin is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  select exists(
    select 1
    from public.admin_sessions s
    where s.token_hash=public.jl_token_hash(p_token)
      and s.admin_id=v_admin
      and s.expires_at>now()
      and s.elevated_until>now()
  ) into v_ok;

  if not v_ok then
    raise exception 'REAUTH_REQUIRED: Confirme novamente o código administrativo para continuar.';
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_require_admin(p_token text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
begin
  if public.jl_admin_account_id(p_token) is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;
end;
$function$
;

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
$function$
;

CREATE OR REPLACE FUNCTION public.jl_require_super_admin(p_token text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_admin uuid:=public.jl_admin_account_id(p_token);
  v_role text;
begin
  if v_admin is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  select role into v_role
  from public.admin_accounts
  where id=v_admin and active;

  if v_role<>'super_admin' then
    raise exception 'Ação permitida apenas ao super administrador.';
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_reverse_cash_wager(p_player_id uuid, p_source_type text, p_reference_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  u record;
  restored numeric:=0;
begin
  for u in
    select *
    from public.deposit_wager_usages
    where player_id=p_player_id
      and source_type=p_source_type
      and reference_id=p_reference_id
      and reversed_at is null
    order by created_at,id
    for update
  loop
    update public.deposit_wager_requirements
    set remaining_amount=remaining_amount+u.amount,
        status='active',
        updated_at=now()
    where id=u.requirement_id;

    update public.deposit_wager_usages
    set reversed_at=now()
    where id=u.id;

    restored:=restored+u.amount;
  end loop;

  return restored;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_rotate_player_session(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  s public.player_sessions%rowtype;
  v_token text;
  v_expires_at timestamptz;
begin
  select * into s
  from public.player_sessions
  where token_hash=public.jl_token_hash(p_token)
    and expires_at>now()
  for update;

  if s.id is null then
    raise exception 'Sessão do jogador inválida ou expirada.';
  end if;

  v_token:=encode(extensions.gen_random_bytes(32),'hex');
  v_expires_at:=now()+interval '30 days';

  update public.player_sessions
  set token_hash=public.jl_token_hash(v_token),
      expires_at=v_expires_at,
      last_seen_at=now(),
      rotated_at=now()
  where id=s.id;

  return jsonb_build_object(
    'ok',true,
    'token',v_token,
    'expires_at',v_expires_at
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_secure_number()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_round_id uuid;
begin
  select id into v_round_id
  from public.game_rounds
  where game_type='number' and status in ('open','locked','closed')
  order by opened_at desc
  limit 1;

  if v_round_id is null then
    raise exception 'Nenhuma rodada ativa do Número Lendário.';
  end if;

  return public.jl_secure_number(v_round_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_secure_number(p_round_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_settings public.game_settings%rowtype;
  v_total numeric;
  v_list integer[];
  v_count integer;
begin
  select * into v_settings from public.game_settings where game_type='number';

  if not exists (
    select 1 from public.game_rounds
    where id=p_round_id and game_type='number' and status in ('open','locked','closed')
  ) then
    raise exception 'Rodada válida do Número Lendário não encontrada.';
  end if;

  select coalesce(sum(amount),0) into v_total
  from public.bets where round_id=p_round_id;

  if v_settings.draw_mode='house_safe_random' and v_total > 0 then
    select array_agg(number order by number) into v_list
    from (
      select n as number, coalesce(sum(b.amount),0) as exposure
      from generate_series(0,10) n
      left join public.bets b on b.round_id=p_round_id and b.selected_number=n
      group by n
    ) x
    where exposure * v_settings.multiplier < v_total;
  else
    select array_agg(number order by number) into v_list
    from (
      select number, exposure,
             min(exposure) over () as min_exposure
      from (
        select n as number, coalesce(sum(b.amount),0) as exposure
        from generate_series(0,10) n
        left join public.bets b on b.round_id=p_round_id and b.selected_number=n
        group by n
      ) s
    ) x
    where exposure=min_exposure;
  end if;

  v_count := coalesce(array_length(v_list,1),0);
  if v_count=0 then
    raise exception 'Nenhum resultado seguro disponível para o Número Lendário.';
  end if;

  return v_list[public.jl_random_index(v_count)];
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_secure_pair(p_round_id uuid)
 RETURNS integer[]
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_settings public.game_settings%rowtype;
  v_total numeric;
  v_list integer[];
  v_count integer;
  v_code integer;
begin
  select * into v_settings from public.game_settings where game_type='pair';

  if not exists (
    select 1 from public.game_rounds
    where id=p_round_id and game_type='pair' and status in ('open','locked','closed')
  ) then
    raise exception 'Rodada válida da Dupla Lendária não encontrada.';
  end if;

  select coalesce(sum(amount),0) into v_total
  from public.pair_bets where round_id=p_round_id;

  if v_settings.draw_mode='house_safe_random' and v_total > 0 then
    select array_agg(code order by code) into v_list
    from (
      select (a*100+b) as code, coalesce(sum(pb.amount),0) as exposure
      from generate_series(0,10) a
      cross join generate_series(0,10) b
      left join public.pair_bets pb
        on pb.round_id=p_round_id and pb.number_a=a and pb.number_b=b
      where a < b
      group by a,b
    ) x
    where exposure * v_settings.multiplier < v_total;
  else
    select array_agg(code order by code) into v_list
    from (
      select code, exposure, min(exposure) over () as min_exposure
      from (
        select (a*100+b) as code, coalesce(sum(pb.amount),0) as exposure
        from generate_series(0,10) a
        cross join generate_series(0,10) b
        left join public.pair_bets pb
          on pb.round_id=p_round_id and pb.number_a=a and pb.number_b=b
        where a < b
        group by a,b
      ) s
    ) x
    where exposure=min_exposure;
  end if;

  v_count := coalesce(array_length(v_list,1),0);
  if v_count=0 then
    raise exception 'Nenhuma combinação segura disponível para a Dupla Lendária.';
  end if;

  v_code := v_list[public.jl_random_index(v_count)];
  return array[(v_code / 100)::integer, (v_code % 100)::integer];
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_social_find_players(p_token text, p_query text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid := public.jl_player_id(p_token);
  q text := trim(coalesce(p_query,''));
begin
  insert into public.ludo_player_codes(player_id)
  select p.id
  from public.players p
  where not p.blocked
    and p.deleted_at is null
    and not exists(select 1 from public.ludo_player_codes c where c.player_id=p.id)
  order by p.created_at,p.id
  on conflict(player_id) do nothing;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'player_id',x.id,
      'name',x.name,
      'code',public.jl_ludo_display_code(x.id),
      'following',exists(
        select 1 from public.player_follows f
        where f.follower_id=me and f.followed_id=x.id
      ),
      'follows_you',exists(
        select 1 from public.player_follows f
        where f.follower_id=x.id and f.followed_id=me
      ),
      'online',exists(
        select 1 from public.player_sessions s
        where s.player_id=x.id
          and s.expires_at>now()
          and s.last_seen_at>=now()-interval '25 seconds'
      ),
      'in_game',exists(
        select 1
        from public.ludo_room_players rp
        join public.ludo_rooms r on r.id=rp.room_id
        where rp.player_id=x.id
          and rp.status<>'left'
          and r.status in ('waiting','negotiating','funding','playing')
      )
    ) order by x.name,public.jl_ludo_display_code(x.id))
    from (
      select p.id,p.name
      from public.players p
      where p.id<>me
        and not p.blocked
        and p.deleted_at is null
        and (
          q=''
          or p.name ilike '%'||q||'%'
          or public.jl_ludo_display_code(p.id) ilike '%'||q||'%'
        )
      order by p.name,p.created_at
      limit 40
    ) x
  ),'[]'::jsonb);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_social_follow(p_token text, p_target_player uuid, p_follow boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid := public.jl_player_id(p_token);
  actor_name text;
  actor_code text;
  is_mutual boolean := false;
  inserted_count integer := 0;
begin
  if p_target_player is null or p_target_player=me then
    raise exception 'Jogador inválido.';
  end if;

  if not exists(
    select 1 from public.players
    where id=p_target_player and not blocked and deleted_at is null
  ) then
    raise exception 'Jogador não encontrado.';
  end if;

  if coalesce(p_follow,true) then
    insert into public.player_follows(follower_id,followed_id)
    values(me,p_target_player)
    on conflict do nothing;
    get diagnostics inserted_count=row_count;

    if inserted_count>0 then
      select name into actor_name from public.players where id=me;
      perform public.jl_ludo_ensure_code(me);
      actor_code:=public.jl_ludo_display_code(me);

      perform public.jl_notification_create(
        p_target_player,
        'follow',
        actor_name||' começou a seguir você',
        actor_code||' adicionou você à lista de jogadores acompanhados.',
        './ludo.html#socialZone',
        null
      );
    end if;
  else
    delete from public.player_follows
    where follower_id=me and followed_id=p_target_player;
  end if;

  select exists(
    select 1 from public.player_follows
    where follower_id=p_target_player and followed_id=me
  ) into is_mutual;

  return jsonb_build_object(
    'ok',true,
    'following',coalesce(p_follow,true),
    'mutual',is_mutual
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_social_list(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid := public.jl_player_id(p_token);
  rows jsonb;
  following_total integer;
  followers_total integer;
  online_total integer;
begin
  update public.player_sessions
  set last_seen_at=now()
  where token_hash=public.jl_token_hash(p_token)
    and expires_at>now();

  insert into public.ludo_player_codes(player_id)
  select p.id
  from public.players p
  where not p.blocked
    and p.deleted_at is null
    and not exists(select 1 from public.ludo_player_codes c where c.player_id=p.id)
  order by p.created_at,p.id
  on conflict(player_id) do nothing;

  select count(*) into following_total
  from public.player_follows
  where follower_id=me;

  select count(*) into followers_total
  from public.player_follows
  where followed_id=me;

  select count(*) into online_total
  from public.player_follows f
  where f.follower_id=me
    and exists(
      select 1
      from public.player_sessions s
      where s.player_id=f.followed_id
        and s.expires_at>now()
        and s.last_seen_at>=now()-interval '25 seconds'
    );

  select coalesce(jsonb_agg(x order by x.online desc, x.name, x.code),'[]'::jsonb)
  into rows
  from (
    select
      p.id as player_id,
      p.name,
      public.jl_ludo_display_code(p.id) as code,
      exists(
        select 1 from public.player_sessions s
        where s.player_id=p.id
          and s.expires_at>now()
          and s.last_seen_at>=now()-interval '25 seconds'
      ) as online,
      exists(
        select 1
        from public.ludo_room_players rp
        join public.ludo_rooms r on r.id=rp.room_id
        where rp.player_id=p.id
          and rp.status<>'left'
          and r.status in ('waiting','negotiating','funding','playing')
      ) as in_game,
      exists(
        select 1 from public.player_follows back
        where back.follower_id=p.id and back.followed_id=me
      ) as mutual,
      f.created_at as followed_at
    from public.player_follows f
    join public.players p on p.id=f.followed_id
    where f.follower_id=me
      and not p.blocked
      and p.deleted_at is null
  ) x;

  return jsonb_build_object(
    'following',rows,
    'following_count',following_total,
    'followers_count',followers_total,
    'online_count',online_total
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_support_send(p_token text, p_message text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid:=public.jl_player_id(p_token);
  msg text:=trim(coalesce(p_message,''));
  mid uuid;
begin
  if char_length(msg)<1 or char_length(msg)>1000 then
    raise exception 'A mensagem deve ter entre 1 e 1000 caracteres.';
  end if;

  insert into public.customer_support_messages(
    player_id,sender,message,read_by_admin,read_by_player
  ) values (
    me,'player',msg,false,true
  ) returning id into mid;

  return jsonb_build_object('ok',true,'id',mid,'message','Mensagem enviada para a Linha de Cliente.');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_support_thread(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  me uuid:=public.jl_player_id(p_token);
  msgs jsonb;
begin
  update public.customer_support_messages
  set read_by_player=true
  where player_id=me and sender='admin' and not read_by_player;

  select coalesce(jsonb_agg(x order by x.created_at),'[]'::jsonb)
  into msgs
  from (
    select id,sender,message,created_at,read_by_player
    from public.customer_support_messages
    where player_id=me
    order by created_at desc
    limit 100
  ) x;

  return jsonb_build_object(
    'messages',msgs,
    'unread_admin_replies',0
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_support_unread_count(p_token text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid:=public.jl_player_id(p_token); c int;
begin
  select count(*) into c
  from public.customer_support_messages
  where player_id=me and sender='admin' and not read_by_player;
  return c;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.jl_token_hash(p_token text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'extensions'
AS $function$
  select encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex');
$function$
;

CREATE OR REPLACE FUNCTION public.jl_validate_invite_code(p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_code text := upper(trim(coalesce(p_code,'')));
  v_name text;
begin
  if v_code = '' then
    return jsonb_build_object('valid',false,'code','');
  end if;

  select i.name
    into v_name
  from public.influencers i
  where i.code = v_code
    and i.active
  limit 1;

  if v_name is null then
    return jsonb_build_object('valid',false,'code',v_code);
  end if;

  return jsonb_build_object(
    'valid',true,
    'code',v_code,
    'influencer',v_name
  );
end;
$function$
;

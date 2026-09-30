create table if not exists public.jl_api_rate_limits(
  scope text not null,
  subject_key text not null,
  window_seconds integer not null check(window_seconds between 1 and 86400),
  window_start timestamptz not null,
  hits integer not null check(hits>0),
  updated_at timestamptz not null default clock_timestamp(),
  primary key(scope,subject_key,window_seconds,window_start)
);

alter table public.jl_api_rate_limits enable row level security;

revoke all on table public.jl_api_rate_limits
from public,anon,authenticated;

grant select on table public.jl_api_rate_limits to service_role;

create index if not exists jl_api_rate_limits_updated_idx
on public.jl_api_rate_limits(updated_at);

create or replace function public.jl_rate_limit_hit(
  p_scope text,
  p_subject_key text,
  p_limit integer,
  p_window_seconds integer
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_now timestamptz:=clock_timestamp();
  v_start timestamptz;
  v_hits integer;
  v_retry_ms integer;
begin
  if p_scope is null or btrim(p_scope)=''
     or p_subject_key is null or btrim(p_subject_key)=''
     or p_limit is null or p_limit<1
     or p_window_seconds is null or p_window_seconds<1 or p_window_seconds>86400 then
    raise exception 'Configuração de rate limit inválida.';
  end if;

  v_start:=to_timestamp(
    floor(extract(epoch from v_now)/p_window_seconds)*p_window_seconds
  );

  insert into public.jl_api_rate_limits(
    scope,subject_key,window_seconds,window_start,hits,updated_at
  )
  values(
    p_scope,p_subject_key,p_window_seconds,v_start,1,v_now
  )
  on conflict(scope,subject_key,window_seconds,window_start)
  do update set
    hits=public.jl_api_rate_limits.hits+1,
    updated_at=excluded.updated_at
  returning hits into v_hits;

  delete from public.jl_api_rate_limits
  where scope=p_scope
    and subject_key=p_subject_key
    and window_start<v_now-interval '1 day';

  v_retry_ms:=greatest(
    1,
    ceil(
      extract(epoch from (v_start+make_interval(secs=>p_window_seconds)-v_now))*1000
    )::integer
  );

  return jsonb_build_object(
    'allowed',v_hits<=p_limit,
    'limit',p_limit,
    'hits',v_hits,
    'remaining',greatest(0,p_limit-v_hits),
    'retry_after_ms',case when v_hits>p_limit then v_retry_ms else 0 end
  );
end;
$function$;

create or replace function public.jl_rate_limit_enforce(
  p_scope text,
  p_subject_key text,
  p_burst_limit integer,
  p_burst_seconds integer,
  p_sustained_limit integer,
  p_sustained_seconds integer
)
returns void
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_burst jsonb;
  v_sustained jsonb;
  v_retry integer:=0;
begin
  v_burst:=public.jl_rate_limit_hit(
    p_scope||':burst',
    p_subject_key,
    p_burst_limit,
    p_burst_seconds
  );

  v_sustained:=public.jl_rate_limit_hit(
    p_scope||':sustained',
    p_subject_key,
    p_sustained_limit,
    p_sustained_seconds
  );

  if not coalesce((v_burst->>'allowed')::boolean,false)
     or not coalesce((v_sustained->>'allowed')::boolean,false) then
    v_retry:=greatest(
      coalesce((v_burst->>'retry_after_ms')::integer,0),
      coalesce((v_sustained->>'retry_after_ms')::integer,0)
    );

    raise exception 'RATE_LIMITED: Muitas requisições. Aguarde % ms e tente novamente.',v_retry;
  end if;
end;
$function$;

revoke all on function public.jl_rate_limit_hit(text,text,integer,integer)
from public,anon,authenticated;

revoke all on function public.jl_rate_limit_enforce(text,text,integer,integer,integer,integer)
from public,anon,authenticated;

grant execute on function public.jl_rate_limit_hit(text,text,integer,integer) to service_role;
grant execute on function public.jl_rate_limit_enforce(text,text,integer,integer,integer,integer) to service_role;


CREATE OR REPLACE FUNCTION public.jl_aviator_place_bet(p_token text, p_amount numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_player_id uuid:=public.jl_player_id(p_token);
declare v_player public.players%rowtype;
declare v_round public.jl_aviator_rounds%rowtype;
declare v_bet public.jl_aviator_bets%rowtype;
begin
  perform public.jl_rate_limit_enforce('aviator_bet',v_player_id::text,6,10,30,60);

  if p_amount is null or p_amount < 1 or p_amount > 1000000 then raise exception 'Valor de aposta invalido.'; end if;
  select * into v_round from public.jl_aviator_rounds where status='OPEN' order by id desc limit 1 for update;
  if v_round.id is null then raise exception 'Nao ha rodada Aviator aberta.'; end if;
  perform public.jl_lock_player_wallet(v_player_id);

  select * into v_player from public.players where id=v_player_id for update;
  if v_player.blocked then raise exception 'Jogador bloqueado.'; end if;
  if v_player.balance < p_amount then raise exception 'Saldo insuficiente.'; end if;

  update public.players set balance=round(balance-p_amount,2),updated_at=now() where id=v_player_id;
  insert into public.jl_aviator_bets(round_id,player_id,stake)
  values(v_round.id,v_player_id,round(p_amount,2)) returning * into v_bet;
  insert into public.transactions(player_id,kind,amount,status,note)
  values(v_player_id,'aviator_bet',-round(p_amount,2),'completed','Aposta Aviator rodada '||v_round.id);
  insert into public.audit_log(action,details)
  values('aviator.bet_placed',jsonb_build_object('roundId',v_round.id,'roundNo',v_round.round_no,'betId',v_bet.id,'betUid',v_bet.bet_uid,'playerId',v_player_id,'stake',v_bet.stake));
  return jsonb_build_object('ok',true,'bet_id',v_bet.id,'bet_uid',v_bet.bet_uid,'round_id',v_round.id,'round_no',v_round.round_no,'stake',v_bet.stake,'balance',v_player.balance-round(p_amount,2));
end $function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_place_bet(p_token text, p_amount numeric, p_request_key text, p_auto_cashout_multiplier numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_player public.players;
  v_round public.jl_aviator_rounds;
  v_bet public.jl_aviator_bets;
  v_existing public.jl_aviator_bets;
  v_enabled boolean;
  v_auto numeric;
  v_tx uuid;
begin
  perform public.jl_rate_limit_enforce('aviator_bet',v_player_id::text,6,10,30,60);

  if p_request_key is null
     or length(trim(p_request_key))<8
     or length(p_request_key)>100 then
    raise exception 'Chave da aposta invalida.';
  end if;

  if p_auto_cashout_multiplier is not null then
    if p_auto_cashout_multiplier<1.01
       or round(p_auto_cashout_multiplier,2)<>p_auto_cashout_multiplier then
      raise exception 'Cash-out automatico deve ser pelo menos 1,01x e usar no maximo 2 casas decimais.';
    end if;
    v_auto:=round(p_auto_cashout_multiplier,2);
  end if;

  perform pg_advisory_xact_lock(
    hashtext(
      'jl_aviator_bet_'||
      v_player_id::text||
      '_'||
      trim(p_request_key)
    )
  );

  perform pg_advisory_xact_lock_shared(
    hashtext('jl_aviator_maintenance')
  );

  select *
    into v_bet
  from public.jl_aviator_bets
  where player_id=v_player_id
    and request_key=p_request_key;

  if v_bet.id is not null then
    select id
      into v_tx
    from public.transactions
    where aviator_bet_id=v_bet.id
      and aviator_operation='BET';

    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'bet_id',v_bet.id,
      'bet_uid',v_bet.bet_uid,
      'round_id',v_bet.round_id,
      'round_no',(select round_no from public.jl_aviator_rounds where id=v_bet.round_id),
      'transaction_id',v_tx,
      'stake',v_bet.stake,
      'auto_cashout_multiplier',v_bet.auto_cashout_multiplier
    );
  end if;

  select enabled
    into v_enabled
  from public.jl_aviator_settings
  where id=true;

  if coalesce(v_enabled,true)=false then
    raise exception 'Aviator em manutencao. Volte em breve.';
  end if;

  if p_amount is null or p_amount<0.50 or p_amount>500 then
    raise exception 'Valor de aposta invalido. Minimo 0,50 MZN e maximo 500 MZN.';
  end if;

  select *
    into v_round
  from public.jl_aviator_rounds
  where status='OPEN'
    and (
      betting_closes_at is null
      or betting_closes_at>clock_timestamp()
    )
  order by id desc
  limit 1
  for share;

  if v_round.id is null then
    raise exception 'Nao ha rodada Aviator aberta.';
  end if;

  perform public.jl_lock_player_wallet(v_player_id);

  select *
    into v_player
  from public.players
  where id=v_player_id
  for update;

  if v_player.blocked then
    raise exception 'Jogador bloqueado.';
  end if;

  select *
    into v_existing
  from public.jl_aviator_bets
  where round_id=v_round.id
    and player_id=v_player_id
  limit 1;

  if v_existing.id is not null then
    raise exception 'Ja existe uma aposta nesta rodada.';
  end if;

  if v_player.balance<p_amount then
    raise exception 'Saldo insuficiente.';
  end if;

  update public.players
     set balance=round(balance-p_amount,2),
         updated_at=clock_timestamp()
   where id=v_player_id;

  insert into public.jl_aviator_bets(
    round_id,
    player_id,
    stake,
    auto_cashout_multiplier,
    request_key
  )
  values(
    v_round.id,
    v_player_id,
    round(p_amount,2),
    v_auto,
    p_request_key
  )
  returning * into v_bet;

  v_tx:=gen_random_uuid();

  insert into public.transactions(
    id,
    player_id,
    kind,
    amount,
    status,
    note,
    aviator_bet_id,
    aviator_operation
  )
  values(
    v_tx,
    v_player_id,
    'aviator_bet',
    -round(p_amount,2),
    'completed',
    'Aposta Aviator rodada '||v_round.id,
    v_bet.id,
    'BET'
  );

  insert into public.audit_log(action,details)
  values(
    'aviator.bet_placed',
    jsonb_build_object(
      'roundId',v_round.id,
      'roundNo',v_round.round_no,
      'betId',v_bet.id,
      'betUid',v_bet.bet_uid,
      'playerId',v_player_id,
      'transactionId',v_tx,
      'stake',v_bet.stake,
      'autoCashoutMultiplier',v_bet.auto_cashout_multiplier
    )
  );

  return jsonb_build_object(
    'ok',true,
    'already_processed',false,
    'bet_id',v_bet.id,
    'bet_uid',v_bet.bet_uid,
    'round_id',v_bet.round_id,
    'round_no',v_round.round_no,
    'transaction_id',v_tx,
    'stake',v_bet.stake,
    'auto_cashout_multiplier',v_bet.auto_cashout_multiplier,
    'balance',v_player.balance-round(p_amount,2)
  );
end
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_cashout(p_token text, p_bet_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_probe public.jl_aviator_bets;
  v_round_id bigint;
  v_round public.jl_aviator_rounds;
  v_cashout_at timestamptz;
  v_m numeric;
begin
  perform public.jl_rate_limit_enforce('aviator_cashout',v_player_id::text,8,10,30,60);

  select *
    into v_probe
  from public.jl_aviator_bets
  where id=p_bet_id
    and player_id=v_player_id;

  if v_probe.id is null then
    raise exception 'Aposta nao encontrada.';
  end if;

  if v_probe.status='CASHED_OUT' then
    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'bet_id',v_probe.id,
      'transaction_id',v_probe.payout_transaction_id,
      'source',v_probe.cashout_source,
      'multiplier',v_probe.cashout_multiplier,
      'payout',v_probe.payout
    );
  end if;

  perform pg_advisory_xact_lock(
    hashtext('jl_aviator_cashout_bet_'||p_bet_id::text)
  );

  select *
    into v_probe
  from public.jl_aviator_bets
  where id=p_bet_id
    and player_id=v_player_id;

  if v_probe.id is null then
    raise exception 'Aposta nao encontrada.';
  end if;

  if v_probe.status='CASHED_OUT' then
    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'bet_id',v_probe.id,
      'transaction_id',v_probe.payout_transaction_id,
      'source',v_probe.cashout_source,
      'multiplier',v_probe.cashout_multiplier,
      'payout',v_probe.payout
    );
  end if;

  if v_probe.status<>'ACTIVE' then
    raise exception 'Aposta ja liquidada.';
  end if;

  v_round_id:=v_probe.round_id;

  perform pg_advisory_xact_lock_shared(
    hashtext('jl_aviator_round_'||v_round_id::text)
  );

  select *
    into v_round
  from public.jl_aviator_rounds
  where id=v_round_id;

  select *
    into v_probe
  from public.jl_aviator_bets
  where id=p_bet_id
    and player_id=v_player_id;

  if v_probe.status='CASHED_OUT' then
    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'bet_id',v_probe.id,
      'transaction_id',v_probe.payout_transaction_id,
      'source',v_probe.cashout_source,
      'multiplier',v_probe.cashout_multiplier,
      'payout',v_probe.payout
    );
  end if;

  if v_probe.status<>'ACTIVE' then
    raise exception 'Aposta ja liquidada.';
  end if;

  if v_round.status<>'FLYING' or v_round.started_at is null then
    raise exception 'Voo nao esta ativo.';
  end if;

  v_cashout_at:=clock_timestamp();
  v_m:=public.jl_aviator_multiplier(
    v_round.started_at,
    v_cashout_at
  );

  if v_m>=coalesce(
    v_round.effective_target,
    v_round.financial_ceiling,
    v_round.visual_target
  ) then
    raise exception 'Crash ja atingido.';
  end if;

  return public.jl_aviator_cashout_locked(
    p_bet_id,
    v_m,
    v_cashout_at,
    'MANUAL'
  );
end
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_reconnect(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_public jsonb;
  v_player jsonb;
begin
  perform public.jl_rate_limit_enforce('aviator_reconnect',v_player_id::text,20,10,120,60);

  -- O engine usa o mesmo advisory lock em modo exclusivo.
  -- Durante esta leitura ele nao pode mudar OPEN/LOCKED/FLYING/CRASHED/SETTLED.
  perform pg_advisory_xact_lock_shared(
    hashtext('jl_aviator_engine_tick')
  );

  v_public:=public.jl_aviator_public_state();
  v_player:=public.jl_aviator_player_state(p_token);

  return jsonb_build_object(
    'server_time',v_public->'server_time',
    'display_at',v_public->'display_at',
    'display_seq',v_public->'display_seq',
    'display_frame_ms',v_public->'display_frame_ms',
    'enabled',v_public->'enabled',
    'maintenance_message',v_public->'maintenance_message',
    'round',v_public->'round',
    'player',v_player
  );
end
$function$;

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
  perform public.jl_rate_limit_enforce(
    'admin_session_base',
    public.jl_token_hash(coalesce(p_token,'')),
    240,10,1200,60
  );

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
$function$;

CREATE OR REPLACE FUNCTION public.jl_require_admin(p_token text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_admin uuid;
begin
  v_admin:=public.jl_admin_account_id(p_token);

  if v_admin is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  perform public.jl_rate_limit_enforce(
    'admin_authenticated',
    v_admin::text,
    60,10,300,60
  );
end;
$function$;

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

  perform public.jl_rate_limit_enforce(
    'admin_elevated',
    v_admin::text,
    15,10,60,60
  );

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
$function$;

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

  perform public.jl_rate_limit_enforce(
    'admin_super',
    v_admin::text,
    30,10,120,60
  );

  select role into v_role
  from public.admin_accounts
  where id=v_admin and active;

  if v_role<>'super_admin' then
    raise exception 'Ação permitida apenas ao super administrador.';
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.jl_admin_session_info(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
begin
  perform public.jl_rate_limit_enforce(
    'admin_session_info',
    public.jl_token_hash(coalesce(p_token,'')),
    30,10,120,60
  );

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
$function$;

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
  perform public.jl_rate_limit_enforce(
    'admin_snapshot_internal',
    'service_role',
    120,10,600,60
  );

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
$function$;
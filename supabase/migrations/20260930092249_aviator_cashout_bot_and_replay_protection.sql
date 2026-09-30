
create table if not exists public.jl_aviator_cashout_guard(
  bet_id bigint primary key
    references public.jl_aviator_bets(id) on delete cascade,
  player_id uuid not null
    references public.players(id) on delete cascade,
  last_attempt_at timestamptz not null,
  total_attempts bigint not null default 1 check(total_attempts>=1),
  blocked_attempts bigint not null default 0 check(blocked_attempts>=0),
  updated_at timestamptz not null default clock_timestamp()
);

alter table public.jl_aviator_cashout_guard enable row level security;
revoke all on table public.jl_aviator_cashout_guard from public,anon,authenticated;
grant select on table public.jl_aviator_cashout_guard to service_role;

create index if not exists jl_aviator_cashout_guard_player_idx
on public.jl_aviator_cashout_guard(player_id,updated_at desc);

create or replace function public.jl_aviator_cashout_bot_guard(
  p_player_id uuid,
  p_bet_id bigint,
  p_min_interval_ms integer default 250
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_row public.jl_aviator_cashout_guard%rowtype;
  v_now timestamptz:=clock_timestamp();
  v_elapsed_ms numeric;
  v_retry_ms integer;
begin
  if p_player_id is null or p_bet_id is null
     or p_min_interval_ms<100 or p_min_interval_ms>5000 then
    raise exception 'Configuração inválida do cash-out guard.';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('jl_aviator_cashout_guard:'||p_bet_id::text,0)
  );

  select *
  into v_row
  from public.jl_aviator_cashout_guard
  where bet_id=p_bet_id
  for update;

  if v_row.bet_id is null then
    insert into public.jl_aviator_cashout_guard(
      bet_id,player_id,last_attempt_at,total_attempts,blocked_attempts,updated_at
    )
    values(
      p_bet_id,p_player_id,v_now,1,0,v_now
    );

    return jsonb_build_object(
      'allowed',true,
      'retry_after_ms',0,
      'reason','FIRST_ATTEMPT'
    );
  end if;

  if v_row.player_id<>p_player_id then
    return jsonb_build_object(
      'allowed',false,
      'retry_after_ms',p_min_interval_ms,
      'reason','OWNER_MISMATCH'
    );
  end if;

  v_elapsed_ms:=extract(epoch from (v_now-v_row.last_attempt_at))*1000;

  if v_elapsed_ms<p_min_interval_ms then
    v_retry_ms:=greatest(1,ceil(p_min_interval_ms-v_elapsed_ms)::integer);

    update public.jl_aviator_cashout_guard
    set total_attempts=total_attempts+1,
        blocked_attempts=blocked_attempts+1,
        updated_at=v_now
    where bet_id=p_bet_id;

    return jsonb_build_object(
      'allowed',false,
      'retry_after_ms',v_retry_ms,
      'reason','TOO_FAST'
    );
  end if;

  update public.jl_aviator_cashout_guard
  set last_attempt_at=v_now,
      total_attempts=total_attempts+1,
      updated_at=v_now
  where bet_id=p_bet_id;

  return jsonb_build_object(
    'allowed',true,
    'retry_after_ms',0,
    'reason','OK'
  );
end;
$function$;

revoke all on function public.jl_aviator_cashout_bot_guard(uuid,bigint,integer)
from public,anon,authenticated;
grant execute on function public.jl_aviator_cashout_bot_guard(uuid,bigint,integer)
to service_role;

CREATE OR REPLACE FUNCTION public.jl_aviator_cashout_core(p_token text, p_bet_id bigint)
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

revoke all on function public.jl_aviator_cashout_core(text,bigint)
from public,anon,authenticated;
grant execute on function public.jl_aviator_cashout_core(text,bigint)
to service_role;

create or replace function public.jl_aviator_cashout(
  p_token text,
  p_bet_id bigint,
  p_request_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog','public'
as $function$
declare
  v_player_id uuid;
  v_bet public.jl_aviator_bets%rowtype;
  v_key text:=btrim(coalesce(p_request_key,''));
  v_subject text;
  v_burst jsonb;
  v_sustained jsonb;
  v_bet_burst jsonb;
  v_bet_sustained jsonb;
  v_guard jsonb;
  v_retry integer:=0;
  v_result jsonb;
  v_error text;
begin
  if length(v_key)<8 or length(v_key)>100 then
    return jsonb_build_object(
      'ok',false,
      'error_code','INVALID_REQUEST_KEY',
      'message','Pedido de cash-out inválido.'
    );
  end if;

  v_subject:=public.jl_token_hash(coalesce(p_token,''));

  -- Persiste mesmo quando autenticação/estado posterior falha.
  v_burst:=public.jl_rate_limit_hit(
    'aviator_cashout_token:burst',v_subject,8,10
  );
  v_sustained:=public.jl_rate_limit_hit(
    'aviator_cashout_token:sustained',v_subject,30,60
  );

  if not (v_burst->>'allowed')::boolean
     or not (v_sustained->>'allowed')::boolean then
    v_retry:=greatest(
      coalesce((v_burst->>'retry_after_ms')::integer,0),
      coalesce((v_sustained->>'retry_after_ms')::integer,0)
    );

    return jsonb_build_object(
      'ok',false,
      'error_code','RATE_LIMITED',
      'message','Muitas tentativas de cash-out. Aguarde um momento.',
      'retry_after_ms',v_retry
    );
  end if;

  begin
    v_player_id:=public.jl_player_id(p_token);
  exception
    when others then
      return jsonb_build_object(
        'ok',false,
        'error_code','AUTH_INVALID',
        'message','Sessão inválida ou expirada.'
      );
  end;

  perform pg_advisory_xact_lock(
    hashtextextended(
      'jl_aviator_cashout_request:'||
      v_player_id::text||':'||v_key,
      0
    )
  );

  select *
  into v_bet
  from public.jl_aviator_bets
  where id=p_bet_id
    and player_id=v_player_id;

  if v_bet.id is null then
    return jsonb_build_object(
      'ok',false,
      'error_code','BET_NOT_FOUND',
      'message','Aposta não encontrada.'
    );
  end if;

  -- Retry de cash-out já concluído é sempre idempotente e não entra no anti-bot.
  if v_bet.status='CASHED_OUT' then
    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'bet_id',v_bet.id,
      'bet_uid',v_bet.bet_uid,
      'round_id',v_bet.round_id,
      'round_no',(select round_no from public.jl_aviator_rounds where id=v_bet.round_id),
      'transaction_id',v_bet.payout_transaction_id,
      'source',v_bet.cashout_source,
      'multiplier',v_bet.cashout_multiplier,
      'payout',v_bet.payout
    );
  end if;

  -- Limite específico da própria aposta: bots não ganham vantagem abrindo várias sessões.
  v_bet_burst:=public.jl_rate_limit_hit(
    'aviator_cashout_bet:burst',p_bet_id::text,2,1
  );
  v_bet_sustained:=public.jl_rate_limit_hit(
    'aviator_cashout_bet:sustained',p_bet_id::text,6,10
  );

  if not (v_bet_burst->>'allowed')::boolean
     or not (v_bet_sustained->>'allowed')::boolean then
    v_retry:=greatest(
      coalesce((v_bet_burst->>'retry_after_ms')::integer,0),
      coalesce((v_bet_sustained->>'retry_after_ms')::integer,0)
    );

    update public.jl_aviator_cashout_guard
    set blocked_attempts=blocked_attempts+1,
        total_attempts=total_attempts+1,
        updated_at=clock_timestamp()
    where bet_id=p_bet_id;

    return jsonb_build_object(
      'ok',false,
      'error_code','BOT_RATE_LIMITED',
      'message','Muitas tentativas de cash-out para esta aposta.',
      'retry_after_ms',v_retry
    );
  end if;

  v_guard:=public.jl_aviator_cashout_bot_guard(
    v_player_id,p_bet_id,250
  );

  if not coalesce((v_guard->>'allowed')::boolean,false) then
    return jsonb_build_object(
      'ok',false,
      'error_code','BOT_TOO_FAST',
      'message','Tentativas de cash-out rápidas demais.',
      'retry_after_ms',coalesce((v_guard->>'retry_after_ms')::integer,250)
    );
  end if;

  -- Tudo que pode falhar financeiramente roda numa subtransação.
  -- Se falhar, dinheiro/estado são revertidos, mas os contadores anti-bot acima permanecem.
  begin
    v_result:=public.jl_aviator_cashout_core(
      p_token,p_bet_id
    );
    return v_result || jsonb_build_object(
      'request_key',v_key
    );
  exception
    when others then
      v_error:=sqlerrm;

      return jsonb_build_object(
        'ok',false,
        'error_code',
          case
            when v_error ilike '%Aposta nao encontrada%' then 'BET_NOT_FOUND'
            when v_error ilike '%Aposta ja liquidada%' then 'BET_SETTLED'
            when v_error ilike '%Voo nao esta ativo%' then 'FLIGHT_INACTIVE'
            when v_error ilike '%Crash ja atingido%' then 'ROUND_CRASHED'
            when v_error ilike '%Jogador bloqueado%' then 'PLAYER_BLOCKED'
            else 'CASHOUT_REJECTED'
          end,
        'message',
          case
            when v_error ilike '%Aposta nao encontrada%' then 'Aposta não encontrada.'
            when v_error ilike '%Aposta ja liquidada%' then 'Esta aposta já terminou.'
            when v_error ilike '%Voo nao esta ativo%' then 'O voo já terminou.'
            when v_error ilike '%Crash ja atingido%' then 'Fim da rodada. Cash-out não disponível.'
            when v_error ilike '%Jogador bloqueado%' then 'A sua conta está bloqueada.'
            else 'Não foi possível concluir o cash-out.'
          end
      );
  end;
end;
$function$;

revoke all on function public.jl_aviator_cashout(text,bigint,text)
from public;
grant execute on function public.jl_aviator_cashout(text,bigint,text)
to anon,authenticated,service_role;

create or replace function public.jl_aviator_cashout(
  p_token text,
  p_bet_id bigint
)
returns jsonb
language sql
security definer
set search_path to 'pg_catalog','public'
as $function$
  select public.jl_aviator_cashout(
    p_token,
    p_bet_id,
    'legacy-cashout:'||p_bet_id::text
  );
$function$;

revoke all on function public.jl_aviator_cashout(text,bigint)
from public;
grant execute on function public.jl_aviator_cashout(text,bigint)
to anon,authenticated,service_role;

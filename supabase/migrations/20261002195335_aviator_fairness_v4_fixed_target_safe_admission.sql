-- Aviator fairness v4: alvo comprometido antes das apostas.
-- A banca e o limite seguro deixam de decidir o ponto de crash.
-- O limite seguro passa a admitir/rejeitar apostas antes do voo.
-- Multiplicador operacional e alvos efetivos ficam limitados a 500x.
-- O alvo v4 e imutavel depois do compromisso/LOCK.

CREATE OR REPLACE FUNCTION public.jl_aviator_operational_target(p_fairness_version text, p_effective_target numeric, p_financial_ceiling numeric, p_visual_target numeric)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  select case
    when p_fairness_version='JL-AVIATOR-PF-v4'
      then least(500::numeric,p_visual_target)
    else least(
      500::numeric,
      coalesce(p_effective_target,p_financial_ceiling,p_visual_target)
    )
  end;
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_fairness_lock_payload_v4(p_round_id bigint, p_seed_commit text, p_total_staked numeric, p_financial_ceiling numeric, p_visual_target numeric, p_locked_effective_target numeric)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE STRICT
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  select concat_ws(
    '|',
    'JL-AVIATOR-PF-v4',
    p_round_id::text,
    p_seed_commit,
    to_char(p_total_staked,'FM999999999999990.00'),
    coalesce(to_char(p_financial_ceiling,'FM999999999999990.000000'),'NULL'),
    to_char(p_visual_target,'FM999999999999990.000000'),
    to_char(p_locked_effective_target,'FM999999999999990.000000')
  );
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_prepare_fairness(p_round_id bigint)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_round public.jl_aviator_rounds;
  v_seed text;
  v_commit text;
  v_u numeric;
  v_target numeric;
  v_version text;
begin
  select *
    into v_round
  from public.jl_aviator_rounds
  where id=p_round_id
  for update;

  if not found then
    raise exception 'Rodada nao encontrada';
  end if;

  if v_round.status<>'OPEN' then
    raise exception 'Fairness so pode ser preparado em rodada OPEN';
  end if;

  -- Nao muda a regra de uma rodada que ja foi comprometida/publicada.
  v_version:=case
    when v_round.fairness_version in ('JL-AVIATOR-PF-v2','JL-AVIATOR-PF-v3','JL-AVIATOR-PF-v4')
      then v_round.fairness_version
    when v_round.round_seed_commit is not null
      then 'JL-AVIATOR-PF-v2'
    else 'JL-AVIATOR-PF-v4'
  end;

  select seed
    into v_seed
  from public.jl_aviator_round_secrets
  where round_id=p_round_id;

  if v_seed is null then
    v_seed:=encode(extensions.gen_random_bytes(32),'hex');
    v_commit:=encode(extensions.digest(v_seed,'sha256'),'hex');
    v_u:=('x'||substr(v_commit,1,13))::bit(52)::bigint::numeric
         / 4503599627370495::numeric;

    insert into public.jl_aviator_round_secrets(round_id,seed,unit_value)
    values(p_round_id,v_seed,v_u)
    on conflict(round_id) do nothing;

    select seed
      into v_seed
    from public.jl_aviator_round_secrets
    where round_id=p_round_id;
  end if;

  v_commit:=encode(extensions.digest(v_seed,'sha256'),'hex');

  v_target:=case
    when v_version in ('JL-AVIATOR-PF-v3','JL-AVIATOR-PF-v4')
      then public.jl_aviator_fairness_visual_target_v3(v_commit)
    else public.jl_aviator_fairness_visual_target(v_commit)
  end;

  if v_round.round_seed_commit is not null
     and v_round.round_seed_commit<>v_commit then
    raise exception 'Commit de fairness inconsistente';
  end if;

  update public.jl_aviator_rounds
     set fairness_version=v_version,
         round_seed_commit=v_commit,
         visual_seed_commit=v_commit,
         visual_target=v_target,
         exposure_ratio_snapshot=case
           when v_version='JL-AVIATOR-PF-v4'
             then coalesce(
               v_round.exposure_ratio_snapshot,
               public.jl_aviator_exposure_ratio_at(clock_timestamp())
             )
           else v_round.exposure_ratio_snapshot
         end,
         round_seed_reveal=null,
         visual_seed_reveal=null
   where id=p_round_id;

  return v_commit;
end
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_lock_round(p_round_id bigint)
 RETURNS jl_aviator_rounds
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
declare
  v_round public.jl_aviator_rounds;
  v_bank public.jl_aviator_bank;
  v_total numeric;
  v_seed text;
  v_commit text;
  v_visual numeric;
  v_financial numeric;
  v_locked_effective numeric;
  v_payload text;
  v_lock_commit text;
  v_exposure_ratio numeric;
  v_version text;
begin
  select *
    into v_round
  from public.jl_aviator_rounds
  where id=p_round_id
  for update;

  if not found or v_round.status<>'OPEN' then
    raise exception 'Rodada nao esta OPEN';
  end if;

  if v_round.round_seed_commit is null
     or not exists(
       select 1 from public.jl_aviator_round_secrets
       where round_id=p_round_id
     ) then
    perform public.jl_aviator_prepare_fairness(p_round_id);

    select *
      into v_round
    from public.jl_aviator_rounds
    where id=p_round_id;
  end if;

  v_version:=case
    when v_round.fairness_version in ('JL-AVIATOR-PF-v2','JL-AVIATOR-PF-v3','JL-AVIATOR-PF-v4')
      then v_round.fairness_version
    else 'JL-AVIATOR-PF-v2'
  end;

  select seed
    into v_seed
  from public.jl_aviator_round_secrets
  where round_id=p_round_id;

  v_commit:=encode(extensions.digest(v_seed,'sha256'),'hex');

  if v_round.round_seed_commit<>v_commit then
    raise exception 'Seed nao corresponde ao compromisso pre-aposta';
  end if;

  v_visual:=case
    when v_version in ('JL-AVIATOR-PF-v3','JL-AVIATOR-PF-v4')
      then public.jl_aviator_fairness_visual_target_v3(v_commit)
    else public.jl_aviator_fairness_visual_target(v_commit)
  end;

  select *
    into v_bank
  from public.jl_aviator_bank
  where id=true
  for update;

  v_exposure_ratio:=case
    when v_version='JL-AVIATOR-PF-v4'
      then coalesce(
        v_round.exposure_ratio_snapshot,
        public.jl_aviator_exposure_ratio_at(clock_timestamp())
      )
    else public.jl_aviator_exposure_ratio_at(clock_timestamp())
  end;

  select coalesce(sum(stake),0)
    into v_total
  from public.jl_aviator_bets
  where round_id=p_round_id
    and status='ACTIVE';

  v_financial:=public.jl_aviator_financial_ceiling(
    v_bank.balance,
    v_total,
    v_exposure_ratio
  );

  v_locked_effective:=case
    when v_version='JL-AVIATOR-PF-v4' then least(500::numeric,v_visual)
    when v_total=0 then v_visual
    else v_financial
  end;

  if v_version='JL-AVIATOR-PF-v4'
     and v_total>0
     and (
       v_financial is null
       or v_financial+0.000001<v_locked_effective
     ) then
    raise exception 'Capacidade segura da rodada inconsistente. A rodada nao pode alterar o alvo comprometido.';
  end if;

  v_payload:=case
    when v_version='JL-AVIATOR-PF-v4' then
      public.jl_aviator_fairness_lock_payload_v4(
        p_round_id,
        v_commit,
        v_total,
        v_financial,
        v_visual,
        v_locked_effective
      )
    when v_version='JL-AVIATOR-PF-v3' then
      public.jl_aviator_fairness_lock_payload_v3(
        p_round_id,
        v_commit,
        v_total,
        v_financial,
        v_visual,
        v_locked_effective
      )
    else
      public.jl_aviator_fairness_lock_payload(
        p_round_id,
        v_commit,
        v_total,
        v_financial,
        v_visual,
        v_locked_effective
      )
  end;

  v_lock_commit:=encode(extensions.digest(v_payload,'sha256'),'hex');

  update public.jl_aviator_rounds
     set status='LOCKED',
         engine_due_at=coalesce(v_round.takeoff_at,clock_timestamp()+interval '3 seconds'),
         locked_at=clock_timestamp(),
         bank_balance_snapshot=v_bank.balance,
         exposure_ratio_snapshot=v_exposure_ratio,
         risk_reserve=round(v_bank.balance*v_exposure_ratio,2),
         total_staked=v_total,
         financial_ceiling=v_financial,
         visual_target=v_visual,
         round_seed_commit=v_commit,
         visual_seed_commit=v_commit,
         lock_proof_commit=v_lock_commit,
         locked_effective_target=v_locked_effective,
         effective_target=v_locked_effective,
         round_seed_reveal=null,
         visual_seed_reveal=null,
         visual_extension=case
           when v_version='JL-AVIATOR-PF-v4' then false
           else (v_total=0)
         end,
         zero_exposure_at_multiplier=case
           when v_version='JL-AVIATOR-PF-v4' then null
           else v_round.zero_exposure_at_multiplier
         end,
         fairness_version=v_version
   where id=p_round_id
  returning * into v_round;

  perform public.jl_aviator_schedule_next_engine_event(p_round_id);

  select *
    into v_round
  from public.jl_aviator_rounds
  where id=p_round_id;

  return v_round;
end;
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_set_visual_target(p_round_id bigint, p_current numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_precommitted numeric;
  v_effective numeric;
  v_version text;
begin
  select visual_target,fairness_version
    into v_precommitted,v_version
  from public.jl_aviator_rounds
  where id=p_round_id
  for update;

  if not found then
    raise exception 'Rodada nao encontrada';
  end if;

  -- v4: o alvo foi comprometido antes das apostas e nunca muda durante o voo.
  if v_version='JL-AVIATOR-PF-v4' then
    return least(500::numeric,v_precommitted);
  end if;

  -- Compatibilidade apenas para rodadas antigas criadas antes desta migration.
  if v_precommitted is null then
    v_precommitted:=public.jl_aviator_extension_target(p_round_id,p_current);

    update public.jl_aviator_rounds
       set visual_target=v_precommitted
     where id=p_round_id;
  end if;

  v_effective:=least(500::numeric,greatest(p_current,v_precommitted));

  update public.jl_aviator_rounds
     set visual_extension=true,
         zero_exposure_at_multiplier=p_current,
         effective_target=v_effective
   where id=p_round_id
     and status='FLYING';

  return v_effective;
end
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_public_state()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
  s record;
  v_now timestamptz:=clock_timestamp();
  v_frame_ms integer:=250;
  v_display_seq bigint;
  v_display_at timestamptz;
  v_public_status text;
  v_phase text;
  v_public_crash numeric;
  v_target numeric;
  v_exact_multiplier numeric:=1;
  v_current_multiplier numeric:=1;
  v_seconds_to_close integer;
  v_seconds_to_takeoff integer;
  v_seconds_to_next_round integer;
  v_takeoff_at timestamptz;
begin
  v_display_seq:=public.jl_aviator_display_seq(v_now,v_frame_ms);
  v_display_at:=
    timestamptz 'epoch'
    + (v_display_seq * v_frame_ms) * interval '1 millisecond';

  select enabled,maintenance_message
    into s
  from public.jl_aviator_settings
  where id=true;

  select
    id,
    round_no,
    status,
    opened_at,
    betting_closes_at,
    takeoff_at,
    locked_at,
    started_at,
    crashed_at,
    settled_at,
    next_round_at,
    crash_multiplier,
    visual_extension,
    visual_seed_commit,
    visual_seed_reveal,
    round_seed_commit,
    round_seed_reveal,
    lock_proof_commit,
    fairness_version,
    proof_published_at,
    effective_target,
    financial_ceiling,
    visual_target
  into r
  from public.jl_aviator_rounds
  order by id desc
  limit 1;

  if r.id is null then
    return jsonb_build_object(
      'server_time',v_now,
      'display_at',v_display_at,
      'display_seq',v_display_seq,
      'display_frame_ms',v_frame_ms,
      'enabled',coalesce(s.enabled,true),
      'maintenance_message',coalesce(
        s.maintenance_message,
        'Aviator em manutencao. Volte em breve.'
      ),
      'round',null
    );
  end if;

  v_public_status:=r.status;
  v_public_crash:=r.crash_multiplier;
  v_takeoff_at:=coalesce(
    r.takeoff_at,
    case
      when r.locked_at is not null then r.locked_at+interval '3 seconds'
      else null
    end
  );

  if r.status='OPEN' and r.betting_closes_at is not null then
    v_seconds_to_close:=greatest(
      0,
      ceil(extract(epoch from (r.betting_closes_at-v_display_at)))
    )::integer;
  else
    v_seconds_to_close:=null;
  end if;

  if r.status in ('OPEN','LOCKED') and v_takeoff_at is not null then
    v_seconds_to_takeoff:=greatest(
      0,
      ceil(extract(epoch from (v_takeoff_at-v_display_at)))
    )::integer;
  else
    v_seconds_to_takeoff:=null;
  end if;

  if r.status in ('CRASHED','SETTLED') and r.next_round_at is not null then
    v_seconds_to_next_round:=greatest(
      0,
      ceil(extract(epoch from (r.next_round_at-v_now)))
    )::integer;
  else
    v_seconds_to_next_round:=null;
  end if;

  if r.status='FLYING' and r.started_at is not null then
    v_target:=public.jl_aviator_operational_target(
      r.fairness_version,
      r.effective_target,
      r.financial_ceiling,
      r.visual_target
    );

    v_exact_multiplier:=public.jl_aviator_multiplier(r.started_at,v_now);

    if v_target is not null and v_exact_multiplier>=v_target then
      v_public_status:='CRASHED';
      v_public_crash:=v_target;
      v_current_multiplier:=v_target;
    else
      v_current_multiplier:=least(
        coalesce(v_target,500::numeric),
        public.jl_aviator_multiplier(
          r.started_at,
          greatest(v_display_at,r.started_at)
        )
      );
    end if;
  elsif r.status in ('CRASHED','SETTLED') then
    v_current_multiplier:=least(
      500::numeric,
      greatest(1,coalesce(r.crash_multiplier,1))
    );
  else
    v_current_multiplier:=1;
  end if;

  v_phase:=case
    when v_public_status='OPEN' then 'BETTING'
    else v_public_status
  end;

  return jsonb_build_object(
    'server_time',v_now,
    'display_at',v_display_at,
    'display_seq',v_display_seq,
    'display_frame_ms',v_frame_ms,
    'enabled',coalesce(s.enabled,true),
    'maintenance_message',coalesce(
      s.maintenance_message,
      'Aviator em manutencao. Volte em breve.'
    ),
    'round',jsonb_build_object(
      'id',r.id,
      'round_no',r.round_no,
      'status',v_public_status,
      'phase',v_phase,
      'display_seq',v_display_seq,
      'display_at',v_display_at,
      'opened_at',r.opened_at,
      'betting_closes_at',r.betting_closes_at,
      'seconds_to_close',v_seconds_to_close,
      'locked_at',r.locked_at,
      'takeoff_at',v_takeoff_at,
      'seconds_to_takeoff',v_seconds_to_takeoff,
      'betting_open',
        r.status='OPEN'
        and r.betting_closes_at is not null
        and v_now<r.betting_closes_at,
      'started_at',r.started_at,
      'current_multiplier',v_current_multiplier,
      'crashed_at',r.crashed_at,
      'settled_at',r.settled_at,
      'next_round_at',r.next_round_at,
      'seconds_to_next_round',v_seconds_to_next_round,
      'crash_multiplier',v_public_crash,
      'visual_extension',r.visual_extension,
      'fairness_version',r.fairness_version,
      'round_seed_commit',coalesce(
        r.round_seed_commit,
        r.visual_seed_commit
      ),
      'lock_proof_commit',r.lock_proof_commit,
      'proof_published_at',r.proof_published_at,
      'round_seed_reveal',
        case
          when r.status in ('CRASHED','SETTLED')
            then coalesce(r.round_seed_reveal,r.visual_seed_reveal)
          else null
        end,
      'visual_seed_commit',coalesce(
        r.round_seed_commit,
        r.visual_seed_commit
      ),
      'visual_seed_reveal',
        case
          when r.status in ('CRASHED','SETTLED')
            then coalesce(r.round_seed_reveal,r.visual_seed_reveal)
          else null
        end
    )
  );
end
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_schedule_next_engine_event(p_round_id bigint)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_round public.jl_aviator_rounds;
  v_target numeric;
  v_auto numeric;
  v_next_multiplier numeric;
  v_due timestamptz;
begin
  select *
    into v_round
  from public.jl_aviator_rounds
  where id=p_round_id
  for update;

  if v_round.id is null then
    return null;
  end if;

  case v_round.status
    when 'OPEN' then
      v_due:=v_round.betting_closes_at;
    when 'LOCKED' then
      v_due:=coalesce(
        v_round.takeoff_at,
        v_round.locked_at+interval '3 seconds',
        clock_timestamp()
      );
    when 'FLYING' then
      v_target:=public.jl_aviator_operational_target(
        v_round.fairness_version,
        v_round.effective_target,
        v_round.financial_ceiling,
        v_round.visual_target
      );

      if v_round.started_at is null or v_target is null then
        v_due:=clock_timestamp();
      else
        select min(b.auto_cashout_multiplier)
          into v_auto
        from public.jl_aviator_bets b
        where b.round_id=p_round_id
          and b.status='ACTIVE'
          and b.auto_cashout_multiplier is not null
          and b.auto_cashout_multiplier<v_target;

        v_next_multiplier:=case
          when v_auto is null then v_target
          else least(v_auto,v_target)
        end;

        v_due:=public.jl_aviator_multiplier_reach_at(
          v_round.started_at,
          v_next_multiplier
        );
      end if;
    when 'CRASHED' then
      v_due:=clock_timestamp();
    else
      v_due:=null;
  end case;

  update public.jl_aviator_rounds
     set engine_due_at=v_due
   where id=p_round_id
     and engine_due_at is distinct from v_due;

  return v_due;
end;
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_place_bet_slot(p_token text, p_amount numeric, p_request_key text, p_auto_cashout_multiplier numeric, p_bet_slot integer)
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
  v_slot smallint;
  v_bank public.jl_aviator_bank;
  v_target numeric;
  v_exposure_ratio numeric;
  v_active_stake numeric:=0;
  v_risk_budget numeric:=0;
  v_required_liability numeric:=0;
  v_server_received_at timestamptz:=clock_timestamp();
begin
  perform public.jl_rate_limit_enforce(
    'aviator_bet',
    v_player_id::text,
    8,10,40,60
  );

  if p_bet_slot not in (1,2) then
    raise exception 'Painel de aposta invalido.';
  end if;
  v_slot:=p_bet_slot::smallint;

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
      v_player_id::text||'_'||
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
    select id into v_tx
    from public.transactions
    where aviator_bet_id=v_bet.id
      and aviator_operation='BET';

    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'bet_id',v_bet.id,
      'bet_uid',v_bet.bet_uid,
      'bet_slot',v_bet.bet_slot,
      'round_id',v_bet.round_id,
      'round_no',(select round_no from public.jl_aviator_rounds where id=v_bet.round_id),
      'transaction_id',v_tx,
      'stake',v_bet.stake,
      'auto_cashout_multiplier',v_bet.auto_cashout_multiplier
    );
  end if;

  select enabled into v_enabled
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
    and betting_closes_at is not null
    and betting_closes_at>v_server_received_at
  order by id desc
  limit 1
  for share;

  if v_round.id is null then
    raise exception 'Nao ha rodada Aviator aberta.';
  end if;

  -- Não aceitar novas apostas numa rodada antiga cuja queda ainda dependa
  -- da exposição. A próxima rodada v4 já nasce com alvo fixo.
  if v_round.fairness_version is distinct from 'JL-AVIATOR-PF-v4' then
    raise exception 'Rodada em transicao de seguranca. Aguarde a proxima rodada.';
  end if;

  v_target:=least(500::numeric,v_round.visual_target);
  if v_target is null or v_target<1 then
    raise exception 'Alvo comprometido da rodada indisponivel.';
  end if;

  -- Uma única fila de capacidade por rodada evita overbooking concorrente.
  perform pg_advisory_xact_lock(
    hashtext('jl_aviator_risk_capacity_'||v_round.id::text)
  );

  select *
    into v_bank
  from public.jl_aviator_bank
  where id=true
  for update;

  v_exposure_ratio:=coalesce(
    v_round.exposure_ratio_snapshot,
    public.jl_aviator_exposure_ratio_at(v_server_received_at)
  );

  select coalesce(sum(stake),0)
    into v_active_stake
  from public.jl_aviator_bets
  where round_id=v_round.id
    and status='ACTIVE';

  v_risk_budget:=greatest(coalesce(v_bank.balance,0)*v_exposure_ratio,0);
  v_required_liability:=greatest(
    (v_active_stake+round(p_amount,2))*(v_target-1),
    0
  );

  if v_required_liability>v_risk_budget+0.000001 then
    raise exception 'Limite seguro da rodada atingido. A aposta nao foi aceite.';
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
    and bet_slot=v_slot
  limit 1;

  if v_existing.id is not null then
    raise exception 'Ja existe uma aposta neste painel nesta rodada.';
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
    request_key,
    bet_slot
  )
  values(
    v_round.id,
    v_player_id,
    round(p_amount,2),
    v_auto,
    p_request_key,
    v_slot
  )
  returning * into v_bet;

  v_tx:=gen_random_uuid();

  insert into public.transactions(
    id,player_id,kind,amount,status,note,
    aviator_bet_id,aviator_operation
  )
  values(
    v_tx,
    v_player_id,
    'aviator_bet',
    -round(p_amount,2),
    'completed',
    'Aposta Aviator painel '||v_slot||' rodada '||v_round.id,
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
      'betSlot',v_slot,
      'playerId',v_player_id,
      'transactionId',v_tx,
      'stake',v_bet.stake,
      'autoCashoutMultiplier',v_bet.auto_cashout_multiplier,
      'serverAcceptedAt',v_bet.created_at
    )
  );

  return jsonb_build_object(
    'ok',true,
    'already_processed',false,
    'bet_id',v_bet.id,
    'bet_uid',v_bet.bet_uid,
    'bet_slot',v_slot,
    'round_id',v_bet.round_id,
    'round_no',v_round.round_no,
    'transaction_id',v_tx,
    'stake',v_bet.stake,
    'auto_cashout_multiplier',v_bet.auto_cashout_multiplier,
    'server_accepted_at',v_bet.created_at,
    'balance',v_player.balance-round(p_amount,2)
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_place_bet(p_token text, p_amount numeric, p_request_key text, p_auto_cashout_multiplier numeric)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  select public.jl_aviator_place_bet_slot(
    p_token,
    p_amount,
    p_request_key,
    p_auto_cashout_multiplier,
    1
  );
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_round_proof(p_round_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  r public.jl_aviator_rounds;
  v_seed text;
  v_seed_commit text;
  v_visual numeric;
  v_payload text;
  v_lock_commit text;
  v_financial numeric;
  v_expected_final numeric;
  v_seed_ok boolean:=false;
  v_visual_ok boolean:=false;
  v_lock_ok boolean:=false;
  v_financial_ok boolean:=false;
  v_result_ok boolean:=false;
  v_capacity_ok boolean:=true;
begin
  select *
    into r
  from public.jl_aviator_rounds
  where id=p_round_id;

  if not found then
    raise exception 'Rodada nao encontrada';
  end if;

  if r.status not in ('CRASHED','SETTLED') then
    return jsonb_build_object(
      'available',false,
      'round_id',r.id,
      'round_no',r.round_no,
      'status',r.status,
      'reason','proof_available_after_crash'
    );
  end if;

  if r.fairness_version not in ('JL-AVIATOR-PF-v2','JL-AVIATOR-PF-v3','JL-AVIATOR-PF-v4') then
    return jsonb_build_object(
      'available',false,
      'round_id',r.id,
      'round_no',r.round_no,
      'status',r.status,
      'reason','legacy_round'
    );
  end if;

  v_seed:=coalesce(r.round_seed_reveal,r.visual_seed_reveal);

  if v_seed is not null then
    v_seed_commit:=encode(extensions.digest(v_seed,'sha256'),'hex');
    v_seed_ok:=v_seed_commit=r.round_seed_commit;
  end if;

  if r.round_seed_commit is not null then
    v_visual:=case
      when r.fairness_version in ('JL-AVIATOR-PF-v3','JL-AVIATOR-PF-v4')
        then public.jl_aviator_fairness_visual_target_v3(r.round_seed_commit)
      else public.jl_aviator_fairness_visual_target(r.round_seed_commit)
    end;
    v_visual_ok:=round(v_visual,6)=round(r.visual_target,6);
  end if;

  v_payload:=case
    when r.fairness_version='JL-AVIATOR-PF-v4' then
      public.jl_aviator_fairness_lock_payload_v4(
        r.id,
        r.round_seed_commit,
        r.total_staked,
        r.financial_ceiling,
        r.visual_target,
        r.locked_effective_target
      )
    when r.fairness_version='JL-AVIATOR-PF-v3' then
      public.jl_aviator_fairness_lock_payload_v3(
        r.id,
        r.round_seed_commit,
        r.total_staked,
        r.financial_ceiling,
        r.visual_target,
        r.locked_effective_target
      )
    else
      public.jl_aviator_fairness_lock_payload(
        r.id,
        r.round_seed_commit,
        r.total_staked,
        r.financial_ceiling,
        r.visual_target,
        r.locked_effective_target
      )
  end;

  v_lock_commit:=encode(extensions.digest(v_payload,'sha256'),'hex');
  v_lock_ok:=v_lock_commit=r.lock_proof_commit;

  v_financial:=public.jl_aviator_financial_ceiling(
    r.bank_balance_snapshot,
    r.total_staked,
    r.exposure_ratio_snapshot
  );

  v_financial_ok:=case
    when r.total_staked=0 then r.financial_ceiling is null
    else round(v_financial,6)=round(r.financial_ceiling,6)
  end;

  v_expected_final:=case
    when r.fairness_version='JL-AVIATOR-PF-v4'
      then least(500::numeric,r.visual_target)
    else least(500::numeric,case
      when r.visual_extension then
        greatest(
          r.visual_target,
          coalesce(r.zero_exposure_at_multiplier,r.visual_target)
        )
      else
        r.locked_effective_target
    end)
  end;

  v_capacity_ok:=case
    when r.fairness_version='JL-AVIATOR-PF-v4' and r.total_staked>0
      then r.financial_ceiling is not null
       and r.financial_ceiling+0.000001>=r.visual_target
    else true
  end;

  v_result_ok:=
    v_expected_final is not null
    and r.crash_multiplier is not null
    and round(v_expected_final,6)=round(r.crash_multiplier,6);

  return jsonb_build_object(
    'available',true,
    'round_id',r.id,
    'round_no',r.round_no,
    'status',r.status,
    'fairness_version',r.fairness_version,
    'seed_commit',r.round_seed_commit,
    'seed',v_seed,
    'lock_commit',r.lock_proof_commit,
    'lock_payload',v_payload,
    'inputs',jsonb_build_object(
      'total_staked',r.total_staked,
      'visual_target',r.visual_target,
      'visual_extension',r.visual_extension,
      'financial_ceiling',r.financial_ceiling,
      'locked_effective_target',r.locked_effective_target,
      'zero_exposure_at_multiplier',r.zero_exposure_at_multiplier
    ),
    'result',jsonb_build_object(
      'actual_crash_multiplier',r.crash_multiplier,
      'expected_crash_multiplier',v_expected_final
    ),
    'checks',jsonb_build_object(
      'result_valid',v_result_ok,
      'lock_commit_valid',v_lock_ok,
      'seed_commit_valid',v_seed_ok,
      'visual_target_valid',v_visual_ok,
      'financial_ceiling_valid',v_financial_ok,
      'safe_capacity_valid',v_capacity_ok
    ),
    'proof_valid',
      v_seed_ok
      and v_visual_ok
      and v_lock_ok
      and v_financial_ok
      and v_capacity_ok
      and v_result_ok,
    'published_at',r.proof_published_at
  );
end
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_accrue_house_profit()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_enabled boolean:=true;
  v_rate numeric:=1.00;
  v_last timestamptz;
  v_now timestamptz:=clock_timestamp();
  v_minutes bigint:=0;
  v_requested numeric:=0;
  v_moved numeric:=0;
  v_bank_after numeric:=0;
  v_profit_after numeric:=0;
  v_new_last timestamptz;
begin
  select
    coalesce(enabled,true),
    coalesce(house_profit_per_minute,1.00)
  into v_enabled,v_rate
  from public.jl_aviator_settings
  where id=true;

  if not coalesce(v_enabled,true) then
    return jsonb_build_object(
      'ok',true,
      'moved',0,
      'minutes',0,
      'rate_per_minute',v_rate,
      'maintenance',true
    );
  end if;

  -- Não reduzir a reserva enquanto uma rodada já tem risco financeiro travado.
  if exists(
    select 1
    from public.jl_aviator_rounds
    where status in ('LOCKED','FLYING')
       or (
         status='OPEN'
         and exists(
           select 1
           from public.jl_aviator_bets b
           where b.round_id=jl_aviator_rounds.id
             and b.status='ACTIVE'
         )
       )
    limit 1
  ) then
    return jsonb_build_object(
      'ok',true,
      'moved',0,
      'minutes',0,
      'rate_per_minute',v_rate,
      'deferred_for_exposure',true
    );
  end if;

  select house_profit_last_accrued_at
    into v_last
  from public.jl_aviator_bank
  where id=true;

  v_last:=coalesce(v_last,v_now);
  v_minutes:=floor(
    greatest(extract(epoch from (v_now-v_last)),0) / 60
  )::bigint;

  if v_minutes<=0 then
    return jsonb_build_object(
      'ok',true,
      'moved',0,
      'minutes',0,
      'rate_per_minute',v_rate
    );
  end if;

  perform pg_advisory_xact_lock(hashtext('jl_aviator_house_profit'));

  select
    house_profit_last_accrued_at,
    balance,
    house_profit_balance
  into v_last,v_bank_after,v_profit_after
  from public.jl_aviator_bank
  where id=true
  for update;

  v_last:=coalesce(v_last,v_now);
  v_minutes:=floor(
    greatest(extract(epoch from (v_now-v_last)),0) / 60
  )::bigint;

  if v_minutes<=0 then
    return jsonb_build_object(
      'ok',true,
      'moved',0,
      'minutes',0,
      'rate_per_minute',v_rate,
      'bank_balance',v_bank_after,
      'house_profit_balance',v_profit_after
    );
  end if;

  v_requested:=round(v_minutes*v_rate,2);
  v_moved:=round(least(v_requested,coalesce(v_bank_after,0)),2);
  v_new_last:=v_last+(v_minutes*interval '1 minute');

  update public.jl_aviator_bank
     set balance=round(balance-v_moved,2),
         house_profit_balance=round(house_profit_balance+v_moved,2),
         house_profit_last_accrued_at=v_new_last,
         updated_at=v_now
   where id=true
  returning balance,house_profit_balance
  into v_bank_after,v_profit_after;

  if v_moved>0 then
    insert into public.jl_aviator_bank_ledger(
      delta,
      balance_after,
      reason,
      request_key
    )
    values(
      -v_moved,
      v_bank_after,
      'Lucro reservado da casa: '||v_minutes||' minuto(s) × '||to_char(v_rate,'FM999999990.00')||' MT',
      'house-profit:'||extract(epoch from v_new_last)::bigint::text
    )
    on conflict do nothing;
  end if;

  return jsonb_build_object(
    'ok',true,
    'moved',v_moved,
    'minutes',v_minutes,
    'rate_per_minute',v_rate,
    'bank_balance',v_bank_after,
    'house_profit_balance',v_profit_after,
    'last_accrued_at',v_new_last
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_admin_adjust_bank(p_token text, p_delta numeric, p_reason text, p_request_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  b public.jl_aviator_bank;
  l public.jl_aviator_bank_ledger;
  v_admin uuid:=public.jl_admin_account_id(p_token);
  v_before jsonb;
  v_after jsonb;
  v_reason text:=left(trim(coalesce(p_reason,'')),160);
begin
  if v_admin is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  if p_request_key is null
     or length(trim(p_request_key))<8
     or length(p_request_key)>100 then
    raise exception 'Chave do ajuste invalida';
  end if;

  perform pg_advisory_xact_lock(hashtext('jl_aviator_bank_adjust'));

  select *
    into l
  from public.jl_aviator_bank_ledger
  where request_key=p_request_key;

  if l.id is not null then
    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'balance',l.balance_after
    );
  end if;

  if p_delta is null or p_delta=0 or abs(p_delta)>100000000 then
    raise exception 'Ajuste invalido';
  end if;

  if length(v_reason)<3 then
    raise exception 'Informe o motivo';
  end if;

  if p_delta<0 and exists(
    select 1
    from public.jl_aviator_rounds r
    where r.status in ('LOCKED','FLYING')
       or (
         r.status='OPEN'
         and exists(
           select 1
           from public.jl_aviator_bets b
           where b.round_id=r.id
             and b.status='ACTIVE'
         )
       )
  ) then
    raise exception 'Nao e permitido retirar fundos reservados para apostas ativas';
  end if;

  select *
    into b
  from public.jl_aviator_bank
  where id=true
  for update;

  v_before:=jsonb_build_object(
    'balance',b.balance,
    'exposure_ratio',b.exposure_ratio
  );

  if b.balance+p_delta<0 then
    raise exception 'Ajuste deixaria a banca negativa';
  end if;

  update public.jl_aviator_bank
     set balance=round(balance+p_delta,2),
         updated_at=now()
   where id=true
  returning * into b;

  insert into public.jl_aviator_bank_ledger(
    delta,balance_after,reason,request_key
  )
  values(
    round(p_delta,2),
    b.balance,
    v_reason,
    p_request_key
  );

  v_after:=jsonb_build_object(
    'balance',b.balance,
    'exposure_ratio',b.exposure_ratio
  );

  insert into public.audit_log(
    action,
    details,
    actor_admin_id,
    actor_session_id,
    actor_name,
    actor_role,
    target_type,
    target_id,
    before_state,
    after_state
  )
  values(
    'aviator.admin.bank_adjusted',
    jsonb_build_object(
      'delta',round(p_delta,2),
      'reason',v_reason,
      'requestKey',p_request_key
    ),
    v_admin,
    nullif(current_setting('jl.admin_session_id',true),'')::uuid,
    nullif(current_setting('jl.admin_name',true),''),
    nullif(current_setting('jl.admin_role',true),''),
    'aviator_bank',
    'global',
    v_before,
    v_after
  );

  return jsonb_build_object(
    'ok',true,
    'already_processed',false,
    'balance',b.balance
  );
end
$function$;

CREATE OR REPLACE FUNCTION public.jl_aviator_reject_v4_target_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
begin
  if old.fairness_version='JL-AVIATOR-PF-v4'
     and old.round_seed_commit is not null then
    if new.visual_target is distinct from old.visual_target then
      raise exception 'Alvo provably fair v4 e imutavel';
    end if;

    if old.status in ('LOCKED','FLYING','CRASHED','SETTLED')
       and (
         new.locked_effective_target is distinct from old.locked_effective_target
         or new.effective_target is distinct from old.effective_target
       ) then
      raise exception 'Alvo efetivo v4 nao pode mudar depois do LOCK';
    end if;
  end if;

  return new;
end;
$function$;


revoke all on function public.jl_aviator_operational_target(text,numeric,numeric,numeric)
from public,anon,authenticated;
grant execute on function public.jl_aviator_operational_target(text,numeric,numeric,numeric)
to service_role;

revoke all on function public.jl_aviator_fairness_lock_payload_v4(bigint,text,numeric,numeric,numeric,numeric)
from public,anon,authenticated;
grant execute on function public.jl_aviator_fairness_lock_payload_v4(bigint,text,numeric,numeric,numeric,numeric)
to service_role;

revoke all on function public.jl_aviator_place_bet(text,numeric,text,numeric)
from public;
grant execute on function public.jl_aviator_place_bet(text,numeric,text,numeric)
to anon,authenticated,service_role;

drop trigger if exists trg_jl_aviator_v4_target_immutable on public.jl_aviator_rounds;
CREATE TRIGGER trg_jl_aviator_v4_target_immutable BEFORE UPDATE ON jl_aviator_rounds FOR EACH ROW EXECUTE FUNCTION jl_aviator_reject_v4_target_mutation();

revoke all on function public.jl_aviator_reject_v4_target_mutation()
from public,anon,authenticated;
grant execute on function public.jl_aviator_reject_v4_target_mutation()
to service_role;

alter table public.jl_aviator_rounds
  drop constraint if exists jl_aviator_effective_target_max_500,
  drop constraint if exists jl_aviator_locked_target_max_500;

alter table public.jl_aviator_rounds
  add constraint jl_aviator_effective_target_max_500
    check (effective_target is null or effective_target<=500),
  add constraint jl_aviator_locked_target_max_500
    check (locked_effective_target is null or locked_effective_target<=500);

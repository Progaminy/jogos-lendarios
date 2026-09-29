-- Aviator Lendario: prova criptografica v2.
-- Objetivos:
-- 1) comprometer a seed ANTES de aceitar/fechar as apostas da rodada;
-- 2) nunca substituir a seed depois de criada;
-- 3) comprometer no LOCK os inputs que determinam o alvo financeiro/visual;
-- 4) revelar a seed somente depois do crash;
-- 5) permitir verificacao publica e independente do resultado final.
--
-- Nota: nas rodadas com apostas ativas, a regra economica existente continua:
-- o alvo travado e o teto financeiro. A seed governa o alvo visual
-- precomprometido e a extensao quando a exposicao chega a zero.

alter table public.jl_aviator_rounds
  add column if not exists fairness_version text,
  add column if not exists round_seed_commit text,
  add column if not exists round_seed_reveal text,
  add column if not exists lock_proof_commit text,
  add column if not exists locked_effective_target numeric(18,6),
  add column if not exists exposure_ratio_snapshot numeric(8,6),
  add column if not exists proof_published_at timestamptz;

create unique index if not exists jl_aviator_round_seed_commit_uidx
on public.jl_aviator_rounds(round_seed_commit)
where round_seed_commit is not null;

create or replace function public.jl_aviator_fairness_visual_target(
  p_seed_commit text
)
returns numeric
language plpgsql
immutable
strict
set search_path=pg_catalog,public
as $$
declare
  v_u numeric;
begin
  if p_seed_commit !~ '^[0-9a-f]{64}$' then
    raise exception 'Commit de seed invalido';
  end if;

  -- 52 bits cabem exatamente no inteiro seguro do JavaScript e oferecem
  -- granularidade suficiente para reproducao identica no navegador.
  v_u:=('x'||substr(p_seed_commit,1,13))::bit(52)::bigint::numeric
       / 4503599627370495::numeric;

  return round(5::numeric + 130.7::numeric*v_u,6);
end
$$;

create or replace function public.jl_aviator_fairness_lock_payload(
  p_round_id bigint,
  p_seed_commit text,
  p_total_staked numeric,
  p_financial_ceiling numeric,
  p_visual_target numeric,
  p_locked_effective_target numeric
)
returns text
language sql
immutable
strict
set search_path=pg_catalog,public
as $$
  select concat_ws(
    '|',
    'JL-AVIATOR-PF-v2',
    p_round_id::text,
    p_seed_commit,
    to_char(p_total_staked,'FM999999999999990.00'),
    coalesce(to_char(p_financial_ceiling,'FM999999999999990.000000'),'NULL'),
    to_char(p_visual_target,'FM999999999999990.000000'),
    to_char(p_locked_effective_target,'FM999999999999990.000000')
  );
$$;

-- A seed nasce enquanto a rodada ainda esta OPEN. Se ja existe segredo,
-- a funcao reutiliza-o; nunca faz UPDATE da seed.
create or replace function public.jl_aviator_prepare_fairness(
  p_round_id bigint
)
returns text
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  v_round public.jl_aviator_rounds;
  v_seed text;
  v_commit text;
  v_u numeric;
  v_target numeric;
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

    -- Em caso de corrida, o primeiro INSERT vence e o segundo usa a seed
    -- ja gravada em vez de a substituir.
    select seed
      into v_seed
    from public.jl_aviator_round_secrets
    where round_id=p_round_id;
  end if;

  v_commit:=encode(extensions.digest(v_seed,'sha256'),'hex');
  v_target:=public.jl_aviator_fairness_visual_target(v_commit);

  if v_round.round_seed_commit is not null
     and v_round.round_seed_commit<>v_commit then
    raise exception 'Commit de fairness inconsistente';
  end if;

  update public.jl_aviator_rounds
     set fairness_version='JL-AVIATOR-PF-v2',
         round_seed_commit=v_commit,
         visual_seed_commit=v_commit,
         visual_target=v_target,
         round_seed_reveal=null,
         visual_seed_reveal=null
   where id=p_round_id;

  return v_commit;
end
$$;

-- Seed imutavel depois da primeira gravacao.
create or replace function public.jl_aviator_reject_seed_mutation()
returns trigger
language plpgsql
set search_path=pg_catalog,public
as $$
begin
  if old.seed is distinct from new.seed
     or old.unit_value is distinct from new.unit_value
     or old.round_id is distinct from new.round_id then
    raise exception 'Seed de rodada Aviator e imutavel';
  end if;
  return new;
end
$$;

drop trigger if exists jl_aviator_round_secret_immutable
on public.jl_aviator_round_secrets;

create trigger jl_aviator_round_secret_immutable
before update on public.jl_aviator_round_secrets
for each row execute function public.jl_aviator_reject_seed_mutation();

create or replace function public.jl_aviator_lock_round(p_round_id bigint)
returns public.jl_aviator_rounds
language plpgsql
security definer
set search_path=public,extensions
as $$
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

  select seed
    into v_seed
  from public.jl_aviator_round_secrets
  where round_id=p_round_id;

  v_commit:=encode(extensions.digest(v_seed,'sha256'),'hex');

  if v_round.round_seed_commit<>v_commit then
    raise exception 'Seed nao corresponde ao compromisso pre-aposta';
  end if;

  v_visual:=public.jl_aviator_fairness_visual_target(v_commit);

  select *
    into v_bank
  from public.jl_aviator_bank
  where id=true
  for update;

  select coalesce(sum(stake),0)
    into v_total
  from public.jl_aviator_bets
  where round_id=p_round_id
    and status='ACTIVE';

  v_financial:=public.jl_aviator_financial_ceiling(
    v_bank.balance,
    v_total,
    v_bank.exposure_ratio
  );

  v_locked_effective:=case
    when v_total=0 then v_visual
    else v_financial
  end;

  v_payload:=public.jl_aviator_fairness_lock_payload(
    p_round_id,
    v_commit,
    v_total,
    v_financial,
    v_visual,
    v_locked_effective
  );

  v_lock_commit:=encode(extensions.digest(v_payload,'sha256'),'hex');

  update public.jl_aviator_rounds
     set status='LOCKED',
         locked_at=now(),
         bank_balance_snapshot=v_bank.balance,
         exposure_ratio_snapshot=v_bank.exposure_ratio,
         risk_reserve=round(v_bank.balance*v_bank.exposure_ratio,2),
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
         visual_extension=(v_total=0),
         fairness_version='JL-AVIATOR-PF-v2'
   where id=p_round_id
  returning * into v_round;

  return v_round;
end
$$;

-- Toda nova rodada publica o hash da seed antes que o jogador possa apostar.
create or replace function public.jl_aviator_open_next_if_due()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  r public.jl_aviator_rounds;
  v_enabled boolean;
  v_commit text;
begin
  perform pg_advisory_xact_lock(hashtext('jl_aviator_engine_tick'));
  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));

  select enabled
    into v_enabled
  from public.jl_aviator_settings
  where id=true;

  if coalesce(v_enabled,true)=false then
    return jsonb_build_object('opened',false,'maintenance',true);
  end if;

  if exists(
    select 1
    from public.jl_aviator_rounds
    where status in ('OPEN','LOCKED','FLYING')
  ) then
    return jsonb_build_object('opened',false);
  end if;

  select *
    into r
  from public.jl_aviator_rounds
  order by id desc
  limit 1;

  if r.id is null
     or r.status='CANCELLED'
     or (
       r.status='SETTLED'
       and coalesce(r.next_round_at,now())<=now()
     ) then
    insert into public.jl_aviator_rounds(status,betting_closes_at)
    values('OPEN',now()+interval '12 seconds')
    returning * into r;

    v_commit:=public.jl_aviator_prepare_fairness(r.id);

    return jsonb_build_object(
      'opened',true,
      'round_id',r.id,
      'seed_commit',v_commit,
      'fairness_version','JL-AVIATOR-PF-v2'
    );
  end if;

  return jsonb_build_object('opened',false);
end
$$;

create or replace function public.jl_aviator_publish_proof(p_round_id bigint)
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  update public.jl_aviator_rounds r
     set visual_seed_reveal=s.seed,
         round_seed_reveal=s.seed,
         proof_published_at=clock_timestamp()
    from public.jl_aviator_round_secrets s
   where r.id=p_round_id
     and s.round_id=p_round_id
     and r.status in ('CRASHED','SETTLED');
end
$$;

-- Prova publica completa para rodadas finalizadas.
create or replace function public.jl_aviator_round_proof(p_round_id bigint)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
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
      'status',r.status,
      'reason','proof_available_after_crash'
    );
  end if;

  if r.fairness_version<>'JL-AVIATOR-PF-v2' then
    return jsonb_build_object(
      'available',false,
      'round_id',r.id,
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
    v_visual:=public.jl_aviator_fairness_visual_target(r.round_seed_commit);
    v_visual_ok:=round(v_visual,6)=round(r.visual_target,6);
  end if;

  v_payload:=public.jl_aviator_fairness_lock_payload(
    r.id,
    r.round_seed_commit,
    r.total_staked,
    r.financial_ceiling,
    r.visual_target,
    r.locked_effective_target
  );

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
    when r.visual_extension then
      greatest(
        r.visual_target,
        coalesce(r.zero_exposure_at_multiplier,r.visual_target)
      )
    else
      r.locked_effective_target
  end;

  v_result_ok:=
    v_expected_final is not null
    and r.crash_multiplier is not null
    and round(v_expected_final,6)=round(r.crash_multiplier,6);

  return jsonb_build_object(
    'available',true,
    'round_id',r.id,
    'status',r.status,
    'fairness_version',r.fairness_version,
    'seed_commit',r.round_seed_commit,
    'seed',v_seed,
    'lock_commit',r.lock_proof_commit,
    'lock_payload',v_payload,
    'inputs',jsonb_build_object(
      'total_staked',r.total_staked,
      'financial_ceiling',r.financial_ceiling,
      'visual_target',r.visual_target,
      'locked_effective_target',r.locked_effective_target,
      'visual_extension',r.visual_extension,
      'zero_exposure_at_multiplier',r.zero_exposure_at_multiplier
    ),
    'result',jsonb_build_object(
      'expected_crash_multiplier',v_expected_final,
      'actual_crash_multiplier',r.crash_multiplier
    ),
    'checks',jsonb_build_object(
      'seed_commit_valid',v_seed_ok,
      'visual_target_valid',v_visual_ok,
      'lock_commit_valid',v_lock_ok,
      'financial_ceiling_valid',v_financial_ok,
      'result_valid',v_result_ok
    ),
    'proof_valid',
      v_seed_ok
      and v_visual_ok
      and v_lock_ok
      and v_financial_ok
      and v_result_ok,
    'published_at',r.proof_published_at
  );
end
$$;

-- Estado publico: commit pre-aposta aparece em OPEN; lock commit aparece
-- assim que a rodada fecha. A seed so aparece depois do crash.
create or replace function public.jl_aviator_public_state()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  r record;
  s record;
  v_now timestamptz:=clock_timestamp();
  v_public_status text;
  v_public_crash numeric;
  v_target numeric;
  v_current_multiplier numeric:=1;
  v_seconds_to_close integer;
begin
  select enabled,maintenance_message
    into s
  from public.jl_aviator_settings
  where id=true;

  select
    id,
    status,
    opened_at,
    betting_closes_at,
    started_at,
    crashed_at,
    settled_at,
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
      'enabled',coalesce(s.enabled,true),
      'maintenance_message',coalesce(s.maintenance_message,'Aviator em manutencao. Volte em breve.'),
      'round',null
    );
  end if;

  v_public_status:=r.status;
  v_public_crash:=r.crash_multiplier;

  if r.status='OPEN' and r.betting_closes_at is not null then
    v_seconds_to_close:=greatest(
      0,
      ceil(extract(epoch from (r.betting_closes_at-v_now)))
    )::integer;
  else
    v_seconds_to_close:=null;
  end if;

  if r.status='FLYING' and r.started_at is not null then
    v_target:=coalesce(r.effective_target,r.financial_ceiling,r.visual_target);
    v_current_multiplier:=public.jl_aviator_multiplier(r.started_at,v_now);

    if v_target is not null and v_current_multiplier>=v_target then
      v_public_status:='CRASHED';
      v_public_crash:=v_target;
      v_current_multiplier:=v_target;
    end if;
  elsif r.status in ('CRASHED','SETTLED') then
    v_current_multiplier:=greatest(1,coalesce(r.crash_multiplier,1));
  else
    v_current_multiplier:=1;
  end if;

  return jsonb_build_object(
    'server_time',v_now,
    'enabled',coalesce(s.enabled,true),
    'maintenance_message',coalesce(s.maintenance_message,'Aviator em manutencao. Volte em breve.'),
    'round',jsonb_build_object(
      'id',r.id,
      'status',v_public_status,
      'opened_at',r.opened_at,
      'betting_closes_at',r.betting_closes_at,
      'seconds_to_close',v_seconds_to_close,
      'started_at',r.started_at,
      'current_multiplier',v_current_multiplier,
      'crashed_at',r.crashed_at,
      'settled_at',r.settled_at,
      'crash_multiplier',v_public_crash,
      'visual_extension',r.visual_extension,
      'fairness_version',r.fairness_version,
      'round_seed_commit',coalesce(r.round_seed_commit,r.visual_seed_commit),
      'lock_proof_commit',r.lock_proof_commit,
      'proof_published_at',r.proof_published_at,
      'round_seed_reveal',
        case
          when r.status in ('CRASHED','SETTLED')
            then coalesce(r.round_seed_reveal,r.visual_seed_reveal)
          else null
        end,
      -- aliases mantidos por compatibilidade com clientes antigos
      'visual_seed_commit',coalesce(r.round_seed_commit,r.visual_seed_commit),
      'visual_seed_reveal',
        case
          when r.status in ('CRASHED','SETTLED')
            then coalesce(r.round_seed_reveal,r.visual_seed_reveal)
          else null
        end
    )
  );
end
$$;

revoke all on function public.jl_aviator_fairness_visual_target(text)
from public,anon,authenticated;
grant execute on function public.jl_aviator_fairness_visual_target(text)
to service_role;

revoke all on function public.jl_aviator_fairness_lock_payload(bigint,text,numeric,numeric,numeric,numeric)
from public,anon,authenticated;
grant execute on function public.jl_aviator_fairness_lock_payload(bigint,text,numeric,numeric,numeric,numeric)
to service_role;

revoke all on function public.jl_aviator_prepare_fairness(bigint)
from public,anon,authenticated;
grant execute on function public.jl_aviator_prepare_fairness(bigint)
to service_role;

revoke all on function public.jl_aviator_lock_round(bigint)
from public,anon,authenticated;
grant execute on function public.jl_aviator_lock_round(bigint)
to service_role;

revoke all on function public.jl_aviator_open_next_if_due()
from public,anon,authenticated;
grant execute on function public.jl_aviator_open_next_if_due()
to service_role;

revoke all on function public.jl_aviator_publish_proof(bigint)
from public,anon,authenticated;
grant execute on function public.jl_aviator_publish_proof(bigint)
to service_role;

revoke all on function public.jl_aviator_round_proof(bigint) from public;
grant execute on function public.jl_aviator_round_proof(bigint)
to anon,authenticated,service_role;

revoke all on function public.jl_aviator_public_state() from public;
grant execute on function public.jl_aviator_public_state()
to anon,authenticated,service_role;

revoke all on function public.jl_aviator_reject_seed_mutation() from public;

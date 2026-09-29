-- Aviator: uma unica fonte de verdade para o multiplicador visivel.
-- Cada resposta publica pertence a um frame canonico de 250 ms do relogio
-- do servidor. O mesmo display_seq produz exatamente o mesmo multiplicador
-- para todos os clientes. Respostas antigas podem ser descartadas pelo cliente.

create or replace function public.jl_aviator_display_seq(
  p_at timestamptz,
  p_frame_ms integer default 250
)
returns bigint
language plpgsql
immutable
strict
set search_path=pg_catalog,public
as $$
begin
  if p_frame_ms < 50 or p_frame_ms > 5000 then
    raise exception 'Frame de display invalido';
  end if;

  return floor(
    extract(epoch from p_at) * 1000::numeric / p_frame_ms::numeric
  )::bigint;
end
$$;

revoke all on function public.jl_aviator_display_seq(timestamptz,integer)
from public,anon,authenticated;
grant execute on function public.jl_aviator_display_seq(timestamptz,integer)
to service_role;

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
  v_frame_ms integer:=250;
  v_display_seq bigint;
  v_display_at timestamptz;
  v_public_status text;
  v_public_crash numeric;
  v_target numeric;
  v_exact_multiplier numeric:=1;
  v_current_multiplier numeric:=1;
  v_seconds_to_close integer;
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

  if r.status='OPEN' and r.betting_closes_at is not null then
    v_seconds_to_close:=greatest(
      0,
      ceil(extract(epoch from (r.betting_closes_at-v_display_at)))
    )::integer;
  else
    v_seconds_to_close:=null;
  end if;

  if r.status='FLYING' and r.started_at is not null then
    v_target:=coalesce(
      r.effective_target,
      r.financial_ceiling,
      r.visual_target
    );

    -- O crash continua a usar o instante real do servidor, sem quantizacao.
    v_exact_multiplier:=public.jl_aviator_multiplier(r.started_at,v_now);

    if v_target is not null and v_exact_multiplier>=v_target then
      v_public_status:='CRASHED';
      v_public_crash:=v_target;
      v_current_multiplier:=v_target;
    else
      -- O numero mostrado e derivado exclusivamente do frame canonico.
      -- Dois clientes no mesmo display_seq recebem exatamente o mesmo valor.
      v_current_multiplier:=public.jl_aviator_multiplier(
        r.started_at,
        greatest(v_display_at,r.started_at)
      );
    end if;
  elsif r.status in ('CRASHED','SETTLED') then
    v_current_multiplier:=greatest(1,coalesce(r.crash_multiplier,1));
  else
    v_current_multiplier:=1;
  end if;

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
      'status',v_public_status,
      'display_seq',v_display_seq,
      'display_at',v_display_at,
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
$$;

revoke all on function public.jl_aviator_public_state() from public;
grant execute on function public.jl_aviator_public_state()
to anon,authenticated,service_role;

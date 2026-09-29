-- Aviator: o navegador deixa de calcular multiplicador e contagem de fecho.
-- O estado publico passa a devolver snapshots calculados pelo relogio do servidor.
-- A UI apenas apresenta current_multiplier/seconds_to_close; cash-out e crash
-- continuam validados no servidor pelas mesmas funcoes financeiras.

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
      'visual_seed_commit',r.visual_seed_commit,
      'visual_seed_reveal',
        case
          when r.status in ('CRASHED','SETTLED') then r.visual_seed_reveal
          else null
        end
    )
  );
end
$$;

revoke all on function public.jl_aviator_public_state() from public;
grant execute on function public.jl_aviator_public_state()
to anon,authenticated,service_role;

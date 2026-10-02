-- Aviator: uma única fase de aposta de 10 segundos.
-- O jogador pode apostar em qualquer instante de 10 a 0.
-- Depois de 0, a rodada entra em LOCKED e a descolagem é agendada
-- a partir do lock concluído, preservando a janela de segurança.

create or replace function public.jl_aviator_open_next_if_due()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r public.jl_aviator_rounds;
  v_enabled boolean;
  v_commit text;
  v_now timestamptz:=clock_timestamp();
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
       and coalesce(r.next_round_at,v_now)<=v_now
     ) then
    insert into public.jl_aviator_rounds(
      status,
      betting_closes_at,
      takeoff_at,
      engine_due_at
    )
    values(
      'OPEN',
      v_now+interval '10 seconds',
      null,
      v_now+interval '10 seconds'
    )
    returning * into r;

    v_commit:=public.jl_aviator_prepare_fairness(r.id);

    return jsonb_build_object(
      'opened',true,
      'round_id',r.id,
      'phase','BETTING',
      'betting_closes_at',r.betting_closes_at,
      'takeoff_at',null,
      'seed_commit',v_commit,
      'fairness_version','JL-AVIATOR-PF-v2'
    );
  end if;

  return jsonb_build_object('opened',false);
end
$function$;

revoke all on function public.jl_aviator_open_next_if_due()
from public,anon,authenticated;
grant execute on function public.jl_aviator_open_next_if_due()
to service_role;

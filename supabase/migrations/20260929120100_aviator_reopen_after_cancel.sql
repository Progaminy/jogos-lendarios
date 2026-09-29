-- Aviator: ao sair de manutencao, uma rodada CANCELLED nao pode bloquear o ciclo.
-- CANCELLED e terminal; quando enabled=true e nao existe rodada viva, a proxima OPEN
-- deve ser criada imediatamente. SETTLED continua respeitando next_round_at.

create or replace function public.jl_aviator_open_next_if_due()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  r public.jl_aviator_rounds;
  v_enabled boolean;
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

    return jsonb_build_object(
      'opened',true,
      'round_id',r.id
    );
  end if;

  return jsonb_build_object('opened',false);
end
$$;

revoke all on function public.jl_aviator_open_next_if_due()
from public,anon,authenticated;

grant execute on function public.jl_aviator_open_next_if_due()
to service_role;

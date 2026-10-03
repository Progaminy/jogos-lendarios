-- Dama Lendária — timeout autoritativo no servidor.
-- Resolve partidas vencidas por tempo mesmo sem nenhum cliente conectado.

create index if not exists dama_rooms_due_timeout_idx
  on public.dama_rooms(action_deadline)
  where status='playing' and action_deadline is not null;

create or replace function public.jl_dama_finalize_due_timeouts(
  p_limit integer default 50
)
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare
  x record;
  winner uuid;
  processed integer:=0;
  lim integer:=greatest(1,least(coalesce(p_limit,50),200));
begin
  for x in
    select r.id,r.current_player_id,r.action_deadline
    from public.dama_rooms r
    where r.status='playing'
      and r.action_deadline is not null
      and r.action_deadline<=now()
      and r.current_player_id is not null
    order by r.action_deadline,r.id
    for update skip locked
    limit lim
  loop
    select rp.player_id
    into winner
    from public.dama_room_players rp
    where rp.room_id=x.id
      and rp.player_id<>x.current_player_id
      and rp.status<>'left'
    order by rp.seat
    limit 1;

    if winner is not null then
      perform public.jl_dama_event(
        x.id,
        x.current_player_id,
        'turn_timeout',
        jsonb_build_object(
          'loser',x.current_player_id,
          'winner',winner,
          'server_finalized',true,
          'deadline',x.action_deadline
        )
      );

      perform public.jl_dama_finish_win(x.id,winner,'timeout');
      processed:=processed+1;
    end if;
  end loop;

  return processed;
end;
$$;

revoke all on function public.jl_dama_finalize_due_timeouts(integer)
from public,anon,authenticated;
grant execute on function public.jl_dama_finalize_due_timeouts(integer)
to service_role;

do $$
declare
  existing_job bigint;
begin
  select jobid into existing_job
  from cron.job
  where jobname='jogos_lendarios_dama_timeout'
  limit 1;

  if existing_job is not null then
    perform cron.unschedule(existing_job);
  end if;

  perform cron.schedule(
    'jogos_lendarios_dama_timeout',
    '15 seconds',
    'select public.jl_dama_finalize_due_timeouts(50);'
  );
end
$$;

-- Jogos Lendários
-- Programação múltipla de sorteios + bloqueio de apostas 3 segundos antes.

create table if not exists public.draw_schedule (
  id uuid primary key default gen_random_uuid(),
  draw_at timestamptz not null unique,
  status text not null default 'pending' check (status in ('pending','active','completed','cancelled','missed')),
  round_id uuid null references public.game_rounds(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.draw_schedule enable row level security;

alter table public.game_rounds add column if not exists draw_at timestamptz;
update public.game_rounds set draw_at = coalesce(drawn_at, closes_at) where draw_at is null;
alter table public.game_rounds alter column draw_at set not null;
alter table public.game_rounds add column if not exists schedule_id uuid null references public.draw_schedule(id) on delete set null;

create index if not exists draw_schedule_status_draw_at_idx on public.draw_schedule(status, draw_at);
create index if not exists game_rounds_status_draw_at_idx on public.game_rounds(status, draw_at);

create or replace function public.jl_open_next_scheduled_round()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.draw_schedule%rowtype;
  v_round public.game_rounds%rowtype;
begin
  if exists (select 1 from public.game_rounds where status in ('open','closed','drawn')) then
    return jsonb_build_object('opened', false, 'reason', 'active_round');
  end if;

  update public.draw_schedule
  set status = 'missed', updated_at = now()
  where status = 'pending' and draw_at <= now() + interval '3 seconds';

  select * into v_item
  from public.draw_schedule
  where status = 'pending'
  order by draw_at
  limit 1
  for update skip locked;

  if v_item.id is null then
    return jsonb_build_object('opened', false, 'reason', 'no_pending_schedule');
  end if;

  insert into public.game_rounds(status, closes_at, draw_at, schedule_id)
  values ('open', v_item.draw_at - interval '3 seconds', v_item.draw_at, v_item.id)
  returning * into v_round;

  update public.draw_schedule
  set status = 'active', round_id = v_round.id, updated_at = now()
  where id = v_item.id;

  return jsonb_build_object(
    'opened', true,
    'round_no', v_round.round_no,
    'closes_at', v_round.closes_at,
    'draw_at', v_round.draw_at,
    'schedule_id', v_item.id
  );
end;
$$;

create or replace function public.jl_finalize_due_rounds()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round public.game_rounds%rowtype;
  v_number integer;
  v_count integer := 0;
begin
  for v_round in
    select *
    from public.game_rounds
    where status in ('open','closed')
      and drawn_number is null
      and draw_at <= now()
    order by draw_at, opened_at
    for update skip locked
  loop
    if v_round.status = 'open' then
      update public.game_rounds
      set status = 'closed', closed_at = coalesce(closed_at, closes_at)
      where id = v_round.id;
    end if;

    v_number := public.jl_secure_number();

    update public.game_rounds
    set status = 'published',
        closed_at = coalesce(closed_at, closes_at),
        drawn_number = v_number,
        drawn_at = now(),
        published_at = now()
    where id = v_round.id;

    update public.bets
    set won = (selected_number = v_number),
        payout = case when selected_number = v_number then round(amount * 10, 2) else 0 end
    where round_id = v_round.id;

    update public.players p
    set balance = p.balance + w.total,
        updated_at = now()
    from (
      select player_id, sum(payout) as total
      from public.bets
      where round_id = v_round.id and won = true
      group by player_id
    ) w
    where p.id = w.player_id;

    insert into public.transactions(player_id, kind, amount, status, reference_id, note)
    select player_id, 'payout', payout, 'completed', id,
           'Prêmio automático da rodada ' || v_round.round_no
    from public.bets
    where round_id = v_round.id and won = true and payout > 0;

    if v_round.schedule_id is not null then
      update public.draw_schedule
      set status = 'completed', updated_at = now()
      where id = v_round.schedule_id;
    end if;

    insert into public.audit_log(action, details)
    values (
      'round.auto_draw_published',
      jsonb_build_object(
        'round_id', v_round.id,
        'round_no', v_round.round_no,
        'drawn_number', v_number,
        'bet_lock_at', v_round.closes_at,
        'scheduled_draw_at', v_round.draw_at,
        'processed_at', now()
      )
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

create or replace function public.jl_process_game_engine()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_closed integer := 0;
  v_drawn integer := 0;
  v_opened jsonb;
begin
  update public.game_rounds
  set status = 'closed', closed_at = coalesce(closed_at, closes_at)
  where status = 'open'
    and closes_at <= now()
    and drawn_number is null;
  get diagnostics v_closed = row_count;

  v_drawn := public.jl_finalize_due_rounds();
  v_opened := public.jl_open_next_scheduled_round();

  return jsonb_build_object('closed', v_closed, 'drawn', v_drawn, 'next', v_opened, 'processed_at', now());
end;
$$;

create or replace function public.jl_admin_schedule_draws(
  p_token text,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_interval_minutes integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inserted integer := 0;
  v_requested integer := 0;
  v_schedule jsonb;
begin
  perform public.jl_require_admin(p_token);

  if p_start_at is null or p_end_at is null then raise exception 'Informe início e fim da programação.'; end if;
  if p_interval_minutes is null or p_interval_minutes < 1 or p_interval_minutes > 1440 then raise exception 'O intervalo deve ficar entre 1 e 1440 minutos.'; end if;
  if p_start_at <= now() + interval '10 seconds' then raise exception 'O primeiro sorteio deve ficar pelo menos 10 segundos no futuro.'; end if;
  if p_end_at < p_start_at then raise exception 'O fim da programação deve ser igual ou posterior ao início.'; end if;
  if p_end_at > now() + interval '7 days' then raise exception 'A programação pode cobrir no máximo os próximos 7 dias.'; end if;

  select count(*) into v_requested
  from generate_series(p_start_at, p_end_at, make_interval(mins => p_interval_minutes));
  if v_requested > 250 then raise exception 'A programação ultrapassa o limite de 250 sorteios por lote.'; end if;

  insert into public.draw_schedule(draw_at)
  select gs
  from generate_series(p_start_at, p_end_at, make_interval(mins => p_interval_minutes)) gs
  on conflict (draw_at) do nothing;
  get diagnostics v_inserted = row_count;

  perform public.jl_process_game_engine();

  select coalesce(jsonb_agg(x order by x.draw_at), '[]'::jsonb) into v_schedule
  from (
    select id, draw_at, status, round_id
    from public.draw_schedule
    where status in ('pending','active')
    order by draw_at
    limit 250
  ) x;

  return jsonb_build_object('ok', true, 'requested', v_requested, 'inserted', v_inserted, 'schedule', v_schedule, 'message', v_inserted || ' horário(s) programado(s).');
end;
$$;

create or replace function public.jl_admin_add_draw_time(p_token text, p_draw_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  perform public.jl_require_admin(p_token);
  if p_draw_at is null or p_draw_at <= now() + interval '10 seconds' or p_draw_at > now() + interval '7 days' then
    raise exception 'Defina um sorteio entre 10 segundos e 7 dias a partir de agora.';
  end if;
  insert into public.draw_schedule(draw_at) values (p_draw_at)
  on conflict (draw_at) do nothing returning id into v_id;
  if v_id is null then raise exception 'Esse horário já está programado.'; end if;
  perform public.jl_process_game_engine();
  return jsonb_build_object('ok', true, 'id', v_id, 'draw_at', p_draw_at, 'message', 'Horário adicionado à programação.');
end;
$$;

create or replace function public.jl_admin_cancel_draw_time(p_token text, p_schedule_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_item public.draw_schedule%rowtype;
begin
  perform public.jl_require_admin(p_token);
  select * into v_item from public.draw_schedule where id = p_schedule_id for update;
  if v_item.id is null then raise exception 'Horário programado não encontrado.'; end if;
  if v_item.status <> 'pending' then raise exception 'Somente horários futuros ainda não ativados podem ser cancelados.'; end if;
  update public.draw_schedule set status='cancelled', updated_at=now() where id=v_item.id;
  return jsonb_build_object('ok', true, 'message', 'Horário cancelado.');
end;
$$;

create or replace function public.jl_admin_clear_draw_schedule(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_count integer := 0;
begin
  perform public.jl_require_admin(p_token);
  update public.draw_schedule set status='cancelled', updated_at=now() where status='pending';
  get diagnostics v_count = row_count;
  return jsonb_build_object('ok', true, 'cancelled', v_count, 'message', v_count || ' horário(s) futuro(s) cancelado(s).');
end;
$$;

-- O projeto em produção também atualiza jl_admin_open_round,
-- jl_admin_close_round, jl_public_state e jl_admin_dashboard para usar draw_at,
-- closes_at = draw_at - 3 seconds e a fila draw_schedule.
-- Consulte o README para as queries de inspeção.

select cron.unschedule(jobid) from cron.job where jobname = 'jogos_lendarios_auto_draw';
select cron.unschedule(jobid) from cron.job where jobname = 'jogos_lendarios_engine';
select cron.schedule('jogos_lendarios_engine', '1 second', 'select public.jl_process_game_engine();');

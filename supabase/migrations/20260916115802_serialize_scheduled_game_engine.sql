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
  if not pg_try_advisory_xact_lock(740112337) then
    return jsonb_build_object('busy', true, 'processed_at', now());
  end if;

  update public.game_rounds
  set status = 'closed',
      closed_at = coalesce(closed_at, closes_at)
  where status = 'open'
    and closes_at <= now()
    and drawn_number is null;
  get diagnostics v_closed = row_count;

  v_drawn := public.jl_finalize_due_rounds();
  v_opened := public.jl_open_next_scheduled_round();

  return jsonb_build_object(
    'closed', v_closed,
    'drawn', v_drawn,
    'next', v_opened,
    'processed_at', now()
  );
end;
$$;

create or replace function public.jl_admin_close_round(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round public.game_rounds%rowtype;
begin
  perform public.jl_require_admin(p_token);

  select * into v_round
  from public.game_rounds
  where status in ('open','closed')
  order by opened_at desc
  limit 1
  for update;

  if v_round.id is null then
    raise exception 'Não há rodada ativa.';
  end if;

  update public.game_rounds
  set status='closed',
      closed_at=now(),
      closes_at=least(closes_at, now()),
      draw_at=now()
  where id=v_round.id;

  perform public.jl_finalize_due_rounds();
  perform public.jl_process_game_engine();

  return jsonb_build_object('ok',true,'round_no',v_round.round_no,'message','Rodada encerrada e sorteada agora. A próxima programação foi ativada, se existir.');
end;
$$;

revoke execute on function public.jl_open_next_scheduled_round() from public;
revoke execute on function public.jl_process_game_engine() from public;
revoke execute on function public.jl_finalize_due_rounds() from public;
revoke execute on function public.jl_secure_number() from public;

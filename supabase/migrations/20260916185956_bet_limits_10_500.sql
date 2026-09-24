create or replace function public.jl_place_bet(
  p_token text,
  p_selected_number integer,
  p_amount numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := public.jl_player_id(p_token);
  v_player public.players%rowtype;
  v_round public.game_rounds%rowtype;
  v_bet_id uuid;
begin
  if p_selected_number < 0 or p_selected_number > 10 then
    raise exception 'Escolha um número de 0 a 10.';
  end if;

  if p_amount is null or p_amount < 10 or p_amount > 500 then
    raise exception 'A aposta deve ser entre 10 e 500 MZN.';
  end if;

  select * into v_round
  from public.game_rounds
  where status = 'open'
    and closes_at > now()
  order by opened_at desc
  limit 1
  for update;

  if v_round.id is null then
    raise exception 'As apostas estão fechadas neste momento.';
  end if;

  select * into v_player
  from public.players
  where id = v_player_id
  for update;

  if v_player.blocked then
    raise exception 'Esta conta está bloqueada.';
  end if;

  if v_player.balance < p_amount then
    raise exception 'Saldo insuficiente para esta aposta.';
  end if;

  update public.players
  set balance = balance - p_amount,
      updated_at = now()
  where id = v_player_id;

  insert into public.bets(round_id, player_id, selected_number, amount)
  values(v_round.id, v_player_id, p_selected_number, round(p_amount, 2))
  returning id into v_bet_id;

  insert into public.transactions(player_id, kind, amount, status, reference_id, note)
  values(v_player_id, 'bet', -round(p_amount, 2), 'completed', v_bet_id, 'Aposta no Número Lendário');

  return jsonb_build_object(
    'ok', true,
    'bet_id', v_bet_id,
    'round_no', v_round.round_no,
    'selected_number', p_selected_number,
    'amount', round(p_amount, 2),
    'balance', v_player.balance - round(p_amount, 2)
  );
end;
$$;

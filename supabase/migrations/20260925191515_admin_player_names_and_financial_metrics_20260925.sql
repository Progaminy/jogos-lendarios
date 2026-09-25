alter table public.admin_metric_baselines
  add column if not exists number_house numeric not null default 0,
  add column if not exists pair_house numeric not null default 0,
  add column if not exists ludo_commission numeric not null default 0;

-- Alinha os novos acumuladores com o último reinício já existente.
update public.admin_metric_baselines b
set number_house = coalesce((
      select sum(bt.amount - bt.payout)
      from public.bets bt
      join public.game_rounds r on r.id = bt.round_id
      where r.game_type = 'number'
        and r.status = 'published'
        and coalesce(r.published_at, r.drawn_at, r.closed_at, r.opened_at) <= b.reset_at
    ), 0),
    pair_house = coalesce((
      select sum(pb.amount - pb.payout)
      from public.pair_bets pb
      join public.game_rounds r on r.id = pb.round_id
      where r.game_type = 'pair'
        and r.status = 'published'
        and coalesce(r.published_at, r.drawn_at, r.closed_at, r.opened_at) <= b.reset_at
    ), 0),
    ludo_commission = coalesce((
      select sum(lp.commission)
      from public.ludo_payouts lp
      where lp.created_at <= b.reset_at
    ), 0)
where b.id = 1;

create or replace function public.jl_admin_financial_summary(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  b public.admin_metric_baselines%rowtype;
  v_players_balance numeric := 0;
  v_player_count integer := 0;
  v_number_raw numeric := 0;
  v_pair_raw numeric := 0;
  v_ludo_raw numeric := 0;
  v_number numeric := 0;
  v_pair numeric := 0;
  v_ludo numeric := 0;
  v_number_house_raw numeric := 0;
  v_pair_house_raw numeric := 0;
  v_ludo_commission_raw numeric := 0;
  v_number_house numeric := 0;
  v_pair_house numeric := 0;
  v_ludo_commission numeric := 0;
begin
  perform public.jl_require_admin(p_token);

  select * into b
  from public.admin_metric_baselines
  where id = 1;

  select coalesce(sum(balance), 0), count(*)
    into v_players_balance, v_player_count
  from public.players
  where deleted_at is null;

  select coalesce(sum(amount), 0) into v_number_raw
  from public.bets;

  select coalesce(sum(amount), 0) into v_pair_raw
  from public.pair_bets;

  select coalesce(-sum(amount) filter (where amount < 0), 0) into v_ludo_raw
  from public.transactions
  where kind in ('ludo_stake', 'ludo_reentry');

  select coalesce(sum(bt.amount - bt.payout), 0)
    into v_number_house_raw
  from public.bets bt
  join public.game_rounds r on r.id = bt.round_id
  where r.game_type = 'number'
    and r.status = 'published';

  select coalesce(sum(pb.amount - pb.payout), 0)
    into v_pair_house_raw
  from public.pair_bets pb
  join public.game_rounds r on r.id = pb.round_id
  where r.game_type = 'pair'
    and r.status = 'published';

  select coalesce(sum(commission), 0)
    into v_ludo_commission_raw
  from public.ludo_payouts;

  v_number := greatest(0, v_number_raw - coalesce(b.number_total, 0));
  v_pair := greatest(0, v_pair_raw - coalesce(b.pair_total, 0));
  v_ludo := greatest(0, v_ludo_raw - coalesce(b.ludo_total, 0));

  v_number_house := v_number_house_raw - coalesce(b.number_house, 0);
  v_pair_house := v_pair_house_raw - coalesce(b.pair_house, 0);
  v_ludo_commission := greatest(0, v_ludo_commission_raw - coalesce(b.ludo_commission, 0));

  return jsonb_build_object(
    'player_balance_total', round(v_players_balance, 2),
    'user_balance_total', round(v_players_balance, 2),
    'player_count', v_player_count,
    'number_total', round(v_number, 2),
    'pair_total', round(v_pair, 2),
    'ludo_total', round(v_ludo, 2),
    'games_total', round(v_number + v_pair + v_ludo, 2),
    'number_house', round(v_number_house, 2),
    'pair_house', round(v_pair_house, 2),
    'ludo_commission', round(v_ludo_commission, 2),
    'house_total', round(v_number_house + v_pair_house + v_ludo_commission, 2),
    'since', b.reset_at
  );
end;
$$;

create or replace function public.jl_admin_reset_financial_counters(
  p_token text,
  p_admin_pin text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text;
  v_number numeric := 0;
  v_pair numeric := 0;
  v_ludo numeric := 0;
  v_number_house numeric := 0;
  v_pair_house numeric := 0;
  v_ludo_commission numeric := 0;
begin
  perform public.jl_require_admin(p_token);

  select code_hash into v_hash
  from public.admin_config
  order by id
  limit 1;

  if v_hash is null
     or encode(extensions.digest(coalesce(p_admin_pin, ''), 'sha256'), 'hex') <> v_hash then
    raise exception 'PIN administrativo incorreto.';
  end if;

  select coalesce(sum(amount), 0) into v_number
  from public.bets;

  select coalesce(sum(amount), 0) into v_pair
  from public.pair_bets;

  select coalesce(-sum(amount) filter (where amount < 0), 0) into v_ludo
  from public.transactions
  where kind in ('ludo_stake', 'ludo_reentry');

  select coalesce(sum(bt.amount - bt.payout), 0)
    into v_number_house
  from public.bets bt
  join public.game_rounds r on r.id = bt.round_id
  where r.game_type = 'number'
    and r.status = 'published';

  select coalesce(sum(pb.amount - pb.payout), 0)
    into v_pair_house
  from public.pair_bets pb
  join public.game_rounds r on r.id = pb.round_id
  where r.game_type = 'pair'
    and r.status = 'published';

  select coalesce(sum(commission), 0)
    into v_ludo_commission
  from public.ludo_payouts;

  insert into public.admin_metric_baselines(
    id, number_total, pair_total, ludo_total,
    number_house, pair_house, ludo_commission, reset_at
  )
  values(
    1, v_number, v_pair, v_ludo,
    v_number_house, v_pair_house, v_ludo_commission, now()
  )
  on conflict (id) do update set
    number_total = excluded.number_total,
    pair_total = excluded.pair_total,
    ludo_total = excluded.ludo_total,
    number_house = excluded.number_house,
    pair_house = excluded.pair_house,
    ludo_commission = excluded.ludo_commission,
    reset_at = excluded.reset_at;

  insert into public.audit_log(action, details)
  values(
    'admin_reset_financial_counters',
    jsonb_build_object(
      'number_baseline', v_number,
      'pair_baseline', v_pair,
      'ludo_baseline', v_ludo,
      'number_house_baseline', v_number_house,
      'pair_house_baseline', v_pair_house,
      'ludo_commission_baseline', v_ludo_commission,
      'at', now()
    )
  );

  return jsonb_build_object(
    'ok', true,
    'message', 'Contagem reiniciada. Saldos e histórico foram preservados.'
  );
end;
$$;

create or replace function public.jl_admin_update_player_name(
  p_token text,
  p_player_id uuid,
  p_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old_name text;
  v_new_name text := regexp_replace(trim(coalesce(p_name, '')), '[[:space:]]+', ' ', 'g');
begin
  perform public.jl_require_admin(p_token);

  if char_length(v_new_name) < 2 or char_length(v_new_name) > 60 then
    raise exception 'O nome deve ter entre 2 e 60 caracteres.';
  end if;

  select name into v_old_name
  from public.players
  where id = p_player_id
    and deleted_at is null
  for update;

  if v_old_name is null then
    raise exception 'Jogador não encontrado.';
  end if;

  update public.players
  set name = v_new_name,
      updated_at = now()
  where id = p_player_id
    and deleted_at is null;

  insert into public.audit_log(action, details)
  values(
    'admin_update_player_name',
    jsonb_build_object(
      'player_id', p_player_id,
      'old_name', v_old_name,
      'new_name', v_new_name,
      'at', now()
    )
  );

  return jsonb_build_object(
    'ok', true,
    'player_id', p_player_id,
    'name', v_new_name,
    'message', 'Nome do jogador atualizado.'
  );
end;
$$;

revoke execute on function public.jl_admin_financial_summary(text) from public, authenticated;
grant execute on function public.jl_admin_financial_summary(text) to anon, service_role;

revoke execute on function public.jl_admin_reset_financial_counters(text, text) from public, authenticated;
grant execute on function public.jl_admin_reset_financial_counters(text, text) to anon, service_role;

revoke execute on function public.jl_admin_update_player_name(text, uuid, text) from public, authenticated;
grant execute on function public.jl_admin_update_player_name(text, uuid, text) to anon, service_role;

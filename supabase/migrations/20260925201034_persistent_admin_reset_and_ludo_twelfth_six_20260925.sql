alter table public.ludo_room_players
  add column if not exists rolls_without_six integer not null default 0;

alter table public.ludo_room_players
  drop constraint if exists ludo_room_players_rolls_without_six_check;

alter table public.ludo_room_players
  add constraint ludo_room_players_rolls_without_six_check
  check (rolls_without_six >= 0);

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
  v_number numeric := 0;
  v_pair numeric := 0;
  v_ludo numeric := 0;
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

  select coalesce(sum(amount), 0)
    into v_number
  from public.bets
  where created_at > b.reset_at;

  select coalesce(sum(amount), 0)
    into v_pair
  from public.pair_bets
  where created_at > b.reset_at;

  select coalesce(-sum(amount) filter (where amount < 0), 0)
    into v_ludo
  from public.transactions
  where kind in ('ludo_stake', 'ludo_reentry')
    and created_at > b.reset_at;

  select coalesce(sum(bt.amount - bt.payout), 0)
    into v_number_house
  from public.bets bt
  join public.game_rounds r on r.id = bt.round_id
  where r.game_type = 'number'
    and r.status = 'published'
    and bt.created_at > b.reset_at;

  select coalesce(sum(pb.amount - pb.payout), 0)
    into v_pair_house
  from public.pair_bets pb
  join public.game_rounds r on r.id = pb.round_id
  where r.game_type = 'pair'
    and r.status = 'published'
    and pb.created_at > b.reset_at;

  select coalesce(sum(lp.commission), 0)
    into v_ludo_commission
  from public.ludo_payouts lp
  join public.ludo_rooms lr on lr.id = lp.room_id
  where lp.created_at > b.reset_at
    and lr.created_at > b.reset_at;

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
  v_reset_at timestamptz := clock_timestamp();
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

  insert into public.admin_metric_baselines(
    id, number_total, pair_total, ludo_total,
    number_house, pair_house, ludo_commission, reset_at
  )
  values(1, 0, 0, 0, 0, 0, 0, v_reset_at)
  on conflict (id) do update set
    number_total = 0,
    pair_total = 0,
    ludo_total = 0,
    number_house = 0,
    pair_house = 0,
    ludo_commission = 0,
    reset_at = excluded.reset_at;

  insert into public.audit_log(action, details)
  values(
    'admin_reset_financial_counters',
    jsonb_build_object(
      'mode', 'timestamp_cutoff',
      'reset_at', v_reset_at,
      'at', now()
    )
  );

  return jsonb_build_object(
    'ok', true,
    'reset_at', v_reset_at,
    'message', 'Contagem reiniciada de forma permanente. Dados anteriores não voltarão ao atualizar.'
  );
end;
$$;

create or replace function public.jl_ludo_roll(p_token text, p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  d int;
  moves jsonb;
  rp public.ludo_room_players%rowtype;
  move_secs int;
  dc int;
  vals jsonb:='[]'::jsonb;
  i int;
  force_six boolean:=false;
  saw_six boolean:=false;
begin
 perform public.jl_ludo_process_timeouts(p_token,p_room);
 select * into r from public.ludo_rooms where id=p_room for update;
 if r.status<>'playing' or r.current_player_id<>me or r.turn_phase<>'roll' then raise exception 'Não é hora de lançar o dado.'; end if;
 if r.action_deadline<=now() then raise exception 'Tempo da jogada expirou.'; end if;
 select * into rp from public.ludo_room_players where room_id=p_room and player_id=me for update;
 dc := coalesce((r.rules->>'dice_count')::int,1);
 force_six := coalesce(rp.rolls_without_six,0) >= 11;

 if dc=1 then
   d:=case when force_six then 6 else public.jl_random_index(6) end;
   update public.ludo_room_players
   set consecutive_sixes=case when d=6 then consecutive_sixes+1 else 0 end,
       rolls_without_six=case when d=6 then 0 else rolls_without_six+1 end
   where room_id=p_room and player_id=me
   returning * into rp;

   perform public.jl_ludo_event(
     p_room,me,'dice_rolled',
     jsonb_build_object(
       'dice',d,
       'count',1,
       'forced_six_after_misses',force_six
     )
   );

   if d=6 and (r.rules->>'three_sixes_penalty')::boolean and rp.consecutive_sixes>=3 then
     perform public.jl_ludo_event(p_room,me,'three_sixes_penalty',jsonb_build_object('dice',d));
     perform public.jl_ludo_advance_turn(p_room,me,false);
     return public.jl_ludo_room_state(p_token,p_room);
   end if;

   moves:=public.jl_ludo_legal_moves_data(p_room,me,d);
   if jsonb_array_length(moves)=0 then
     perform public.jl_ludo_event(p_room,me,'no_legal_move',jsonb_build_object('dice',d));
     perform public.jl_ludo_advance_turn(p_room,me,d=6 and (r.rules->>'six_extra_turn')::boolean);
   else
     move_secs:=(r.rules->>'move_seconds')::int;
     update public.ludo_rooms
     set dice_result=d,
         dice_values=jsonb_build_array(d),
         dice_position=0,
         turn_phase='move',
         action_deadline=now()+make_interval(secs=>move_secs),
         updated_at=now()
     where id=p_room;
   end if;
 else
   update public.ludo_room_players
   set consecutive_sixes=0
   where room_id=p_room and player_id=me;

   for i in 1..dc loop
     d:=case when force_six and i=1 then 6 else public.jl_random_index(6) end;
     if d=6 then saw_six:=true; end if;
     vals:=vals||jsonb_build_array(d);
   end loop;

   update public.ludo_room_players
   set rolls_without_six=case when saw_six then 0 else rolls_without_six+1 end
   where room_id=p_room and player_id=me
   returning * into rp;

   update public.ludo_rooms
   set dice_values=vals,
       dice_position=-1,
       dice_result=null,
       updated_at=now()
   where id=p_room;

   perform public.jl_ludo_event(
     p_room,me,'dice_rolled',
     jsonb_build_object(
       'dice_values',vals,
       'count',dc,
       'forced_six_after_misses',force_six
     )
   );
   perform public.jl_ludo_continue_multi_dice(p_room,me);
 end if;

 return public.jl_ludo_room_state(p_token,p_room);
end;
$$;

revoke execute on function public.jl_admin_financial_summary(text) from public, authenticated;
grant execute on function public.jl_admin_financial_summary(text) to anon, service_role;

revoke execute on function public.jl_admin_reset_financial_counters(text, text) from public, authenticated;
grant execute on function public.jl_admin_reset_financial_counters(text, text) to anon, service_role;

alter table public.pair_bets drop constraint if exists pair_bets_number_a_check;
alter table public.pair_bets add constraint pair_bets_number_a_check check (number_a between 0 and 10);
alter table public.pair_bets drop constraint if exists pair_bets_number_b_check;
alter table public.pair_bets add constraint pair_bets_number_b_check check (number_b between 0 and 10);

alter table public.game_rounds drop constraint if exists game_rounds_pair_drawn_a_check;
alter table public.game_rounds add constraint game_rounds_pair_drawn_a_check check (pair_drawn_a is null or pair_drawn_a between 0 and 10);
alter table public.game_rounds drop constraint if exists game_rounds_pair_drawn_b_check;
alter table public.game_rounds add constraint game_rounds_pair_drawn_b_check check (pair_drawn_b is null or pair_drawn_b between 0 and 10);

create or replace function public.jl_secure_pair(p_round_id uuid)
returns integer[]
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_settings public.game_settings%rowtype;
  v_total numeric;
  v_list integer[];
  v_count integer;
  v_code integer;
begin
  select * into v_settings from public.game_settings where game_type='pair';

  if not exists (
    select 1 from public.game_rounds
    where id=p_round_id and game_type='pair' and status in ('open','locked','closed')
  ) then
    raise exception 'Rodada válida da Dupla Lendária não encontrada.';
  end if;

  select coalesce(sum(amount),0) into v_total
  from public.pair_bets where round_id=p_round_id;

  if v_settings.draw_mode='house_safe_random' and v_total > 0 then
    select array_agg(code order by code) into v_list
    from (
      select (a*100+b) as code, coalesce(sum(pb.amount),0) as exposure
      from generate_series(0,10) a
      cross join generate_series(0,10) b
      left join public.pair_bets pb
        on pb.round_id=p_round_id and pb.number_a=a and pb.number_b=b
      where a < b
      group by a,b
    ) x
    where exposure * v_settings.multiplier < v_total;
  else
    select array_agg(code order by code) into v_list
    from (
      select code, exposure, min(exposure) over () as min_exposure
      from (
        select (a*100+b) as code, coalesce(sum(pb.amount),0) as exposure
        from generate_series(0,10) a
        cross join generate_series(0,10) b
        left join public.pair_bets pb
          on pb.round_id=p_round_id and pb.number_a=a and pb.number_b=b
        where a < b
        group by a,b
      ) s
    ) x
    where exposure=min_exposure;
  end if;

  v_count := coalesce(array_length(v_list,1),0);
  if v_count=0 then
    raise exception 'Nenhuma combinação segura disponível para a Dupla Lendária.';
  end if;

  v_code := v_list[public.jl_random_index(v_count)];
  return array[(v_code / 100)::integer, (v_code % 100)::integer];
end;
$$;

create or replace function public.jl_place_pair_bet(
  p_token text,
  p_number_a integer,
  p_number_b integer,
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
  v_settings public.game_settings%rowtype;
  v_bet_id uuid;
  v_a integer;
  v_b integer;
  v_total_after numeric;
  v_min_after numeric;
begin
  select * into v_settings from public.game_settings where game_type='pair';
  if not v_settings.enabled then raise exception 'Dupla Lendária está temporariamente desativada.'; end if;

  if p_number_a is null or p_number_b is null then raise exception 'Escolha dois números.'; end if;
  if p_number_a < 0 or p_number_a > 10 or p_number_b < 0 or p_number_b > 10 then
    raise exception 'Escolha dois números entre 0 e 10.';
  end if;
  if p_number_a = p_number_b then raise exception 'Escolha dois números diferentes.'; end if;

  v_a := least(p_number_a,p_number_b);
  v_b := greatest(p_number_a,p_number_b);

  if p_amount is null or p_amount < v_settings.min_bet or p_amount > v_settings.max_bet then
    raise exception 'A aposta deve ser entre % e % MZN.', v_settings.min_bet, v_settings.max_bet;
  end if;

  select * into v_round
  from public.game_rounds
  where game_type='pair' and status='open' and closes_at > now()
  order by opened_at desc limit 1 for update;
  if v_round.id is null then raise exception 'As apostas da Dupla Lendária estão fechadas neste momento.'; end if;

  select * into v_player from public.players where id=v_player_id for update;
  if v_player.blocked then raise exception 'Esta conta está bloqueada.'; end if;
  if v_player.balance < p_amount then raise exception 'Saldo insuficiente para esta aposta.'; end if;

  select coalesce(sum(amount),0) + p_amount into v_total_after
  from public.pair_bets where round_id=v_round.id;

  select min(exposure) into v_min_after
  from (
    select a,b,
      coalesce(sum(pb.amount),0)
      + case when a=v_a and b=v_b then p_amount else 0 end as exposure
    from generate_series(0,10) a
    cross join generate_series(0,10) b
    left join public.pair_bets pb
      on pb.round_id=v_round.id and pb.number_a=a and pb.number_b=b
    where a < b
    group by a,b
  ) x;

  if v_min_after * v_settings.multiplier >= v_total_after then
    raise exception 'Esta aposta atingiria o limite de segurança da rodada. Escolha outra combinação ou aguarde a próxima rodada.';
  end if;

  update public.players set balance=balance-p_amount, updated_at=now() where id=v_player_id;
  insert into public.pair_bets(round_id,player_id,number_a,number_b,amount)
  values(v_round.id,v_player_id,v_a,v_b,round(p_amount,2))
  returning id into v_bet_id;

  insert into public.transactions(player_id,kind,amount,status,reference_id,note)
  values(v_player_id,'bet',-round(p_amount,2),'completed',v_bet_id,'Aposta Dupla Lendária '||v_a||'+'||v_b);

  return jsonb_build_object(
    'ok',true,'bet_id',v_bet_id,'round_no',v_round.round_no,
    'number_a',v_a,'number_b',v_b,'amount',round(p_amount,2),
    'balance',v_player.balance-round(p_amount,2)
  );
end;
$$;

create or replace function public.jl_admin_game_snapshot(p_game_type text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round public.game_rounds%rowtype;
  v_last public.game_rounds%rowtype;
  v_settings public.game_settings%rowtype;
  v_schedule jsonb;
  v_stats jsonb;
  v_recent jsonb;
  v_total numeric := 0;
  v_min_exposure numeric := 0;
  v_safe_count integer := 0;
  v_outcome_count integer := 0;
begin
  select * into v_settings from public.game_settings where game_type=p_game_type;
  select * into v_round from public.game_rounds
    where game_type=p_game_type and status in ('open','locked','closed')
    order by opened_at desc limit 1;
  select * into v_last from public.game_rounds
    where game_type=p_game_type and status='published'
    order by published_at desc nulls last,opened_at desc limit 1;

  select coalesce(jsonb_agg(x order by x.draw_at),'[]'::jsonb) into v_schedule
  from (
    select id,draw_at,status,round_id,created_at
    from public.draw_schedule
    where game_type=p_game_type and status in ('pending','active')
    order by draw_at limit 250
  ) x;

  if p_game_type='number' then
    v_outcome_count := 11;
    select coalesce(sum(amount),0) into v_total from public.bets where round_id=v_round.id;

    select coalesce(jsonb_agg(jsonb_build_object(
      'number',n,'bets',coalesce(s.bet_count,0),'total',coalesce(s.total,0)
    ) order by n),'[]'::jsonb) into v_stats
    from generate_series(0,10) n
    left join (
      select selected_number,count(*)::int bet_count,sum(amount)::numeric total
      from public.bets where round_id=v_round.id group by selected_number
    ) s on s.selected_number=n;

    select coalesce(min(exposure),0),
           case when v_total=0 then 11 else count(*) filter (where exposure*v_settings.multiplier < v_total) end
    into v_min_exposure,v_safe_count
    from (
      select n,coalesce(sum(b.amount),0) exposure
      from generate_series(0,10) n
      left join public.bets b on b.round_id=v_round.id and b.selected_number=n
      group by n
    ) e;

    select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_recent
    from (
      select b.id,b.selected_number,b.amount,b.won,b.payout,b.created_at,p.name,p.phone,r.round_no
      from public.bets b join public.players p on p.id=b.player_id join public.game_rounds r on r.id=b.round_id
      order by b.created_at desc limit 100
    ) x;
  else
    v_outcome_count := 55;
    select coalesce(sum(amount),0) into v_total from public.pair_bets where round_id=v_round.id;

    select coalesce(jsonb_agg(jsonb_build_object(
      'number_a',c.a,'number_b',c.b,'bets',coalesce(s.bet_count,0),'total',coalesce(s.total,0)
    ) order by c.a,c.b),'[]'::jsonb) into v_stats
    from (
      select a,b from generate_series(0,10) a cross join generate_series(0,10) b where a<b
    ) c
    left join (
      select number_a,number_b,count(*)::int bet_count,sum(amount)::numeric total
      from public.pair_bets where round_id=v_round.id group by number_a,number_b
    ) s on s.number_a=c.a and s.number_b=c.b;

    select coalesce(min(exposure),0),
           case when v_total=0 then 55 else count(*) filter (where exposure*v_settings.multiplier < v_total) end
    into v_min_exposure,v_safe_count
    from (
      select a,b,coalesce(sum(pb.amount),0) exposure
      from generate_series(0,10) a
      cross join generate_series(0,10) b
      left join public.pair_bets pb on pb.round_id=v_round.id and pb.number_a=a and pb.number_b=b
      where a<b
      group by a,b
    ) e;

    select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_recent
    from (
      select pb.id,pb.number_a,pb.number_b,pb.amount,pb.won,pb.payout,pb.created_at,p.name,p.phone,r.round_no
      from public.pair_bets pb join public.players p on p.id=pb.player_id join public.game_rounds r on r.id=pb.round_id
      order by pb.created_at desc limit 100
    ) x;
  end if;

  return jsonb_build_object(
    'game_type',p_game_type,
    'settings',to_jsonb(v_settings),
    'round',case when v_round.id is null then null else jsonb_build_object(
      'id',v_round.id,'round_no',v_round.round_no,'status',v_round.status,
      'opened_at',v_round.opened_at,'closes_at',v_round.closes_at,
      'draw_at',v_round.draw_at,'schedule_id',v_round.schedule_id
    ) end,
    'last_result',case when v_last.id is null then null else jsonb_build_object(
      'round_no',v_last.round_no,'drawn_number',v_last.drawn_number,
      'pair_drawn_a',v_last.pair_drawn_a,'pair_drawn_b',v_last.pair_drawn_b,
      'drawn_at',v_last.drawn_at,'published_at',v_last.published_at
    ) end,
    'financial',jsonb_build_object(
      'outcome_count',v_outcome_count,
      'total_staked',v_total,
      'min_exposure',v_min_exposure,
      'payout_at_min',round(v_min_exposure*v_settings.multiplier,2),
      'house_floor_at_min',round(v_total-(v_min_exposure*v_settings.multiplier),2),
      'safe_outcomes',v_safe_count
    ),
    'stats',v_stats,'schedule',v_schedule,'recent_bets',v_recent
  );
end;
$$;

create table if not exists public.deposit_wager_requirements (
  id uuid primary key default extensions.gen_random_uuid(),
  deposit_request_id uuid not null unique references public.deposit_requests(id) on delete restrict,
  player_id uuid not null references public.players(id) on delete restrict,
  original_amount numeric not null check (original_amount>0),
  remaining_amount numeric not null check (remaining_amount>=0),
  status text not null default 'active' check (status in ('active','cleared','cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.deposit_wager_requirements enable row level security;

create index if not exists deposit_wager_requirements_player_active_idx
on public.deposit_wager_requirements(player_id,created_at)
where status='active' and remaining_amount>0;

create table if not exists public.deposit_wager_usages (
  id uuid primary key default extensions.gen_random_uuid(),
  requirement_id uuid not null references public.deposit_wager_requirements(id) on delete restrict,
  player_id uuid not null references public.players(id) on delete restrict,
  source_type text not null check (source_type in ('number_bet','pair_bet','ludo_stake','ludo_reentry')),
  reference_id uuid not null,
  amount numeric not null check (amount>0),
  created_at timestamptz not null default now(),
  reversed_at timestamptz
);

alter table public.deposit_wager_usages enable row level security;

create index if not exists deposit_wager_usages_reference_idx
on public.deposit_wager_usages(player_id,source_type,reference_id)
where reversed_at is null;

create or replace function public.jl_deposit_wager_locked(p_player_id uuid)
returns numeric
language sql
security definer
set search_path=public
as $$
  select coalesce(sum(remaining_amount),0)
  from public.deposit_wager_requirements
  where player_id=p_player_id
    and status='active'
    and remaining_amount>0;
$$;

revoke all on function public.jl_deposit_wager_locked(uuid) from public,anon,authenticated;

create or replace function public.jl_apply_cash_wager(
  p_player_id uuid,
  p_amount numeric,
  p_source_type text,
  p_reference_id uuid
)
returns numeric
language plpgsql
security definer
set search_path=public
as $$
declare
  r public.deposit_wager_requirements%rowtype;
  need numeric:=greatest(0,coalesce(p_amount,0));
  take numeric;
  cleared numeric:=0;
begin
  if p_source_type not in ('number_bet','pair_bet','ludo_stake','ludo_reentry') then
    raise exception 'Origem de jogo inválida.';
  end if;
  if need<=0 then return 0; end if;

  for r in
    select *
    from public.deposit_wager_requirements
    where player_id=p_player_id
      and status='active'
      and remaining_amount>0
    order by created_at,id
    for update
  loop
    exit when need<=0;
    take:=least(need,r.remaining_amount);

    update public.deposit_wager_requirements
    set remaining_amount=remaining_amount-take,
        status=case when remaining_amount-take<=0 then 'cleared' else 'active' end,
        updated_at=now()
    where id=r.id;

    insert into public.deposit_wager_usages(
      requirement_id,player_id,source_type,reference_id,amount
    ) values (
      r.id,p_player_id,p_source_type,p_reference_id,take
    );

    cleared:=cleared+take;
    need:=need-take;
  end loop;

  return cleared;
end;
$$;

revoke all on function public.jl_apply_cash_wager(uuid,numeric,text,uuid) from public,anon,authenticated;

create or replace function public.jl_reverse_cash_wager(
  p_player_id uuid,
  p_source_type text,
  p_reference_id uuid
)
returns numeric
language plpgsql
security definer
set search_path=public
as $$
declare
  u record;
  restored numeric:=0;
begin
  for u in
    select *
    from public.deposit_wager_usages
    where player_id=p_player_id
      and source_type=p_source_type
      and reference_id=p_reference_id
      and reversed_at is null
    order by created_at,id
    for update
  loop
    update public.deposit_wager_requirements
    set remaining_amount=remaining_amount+u.amount,
        status='active',
        updated_at=now()
    where id=u.requirement_id;

    update public.deposit_wager_usages
    set reversed_at=now()
    where id=u.id;

    restored:=restored+u.amount;
  end loop;

  return restored;
end;
$$;

revoke all on function public.jl_reverse_cash_wager(uuid,text,uuid) from public,anon,authenticated;

create or replace function public.jl_admin_review_deposit(
  p_token text,
  p_request_id uuid,
  p_decision text
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_req public.deposit_requests%rowtype;
begin
  perform public.jl_require_admin(p_token);

  if p_decision not in ('approved','rejected') then
    raise exception 'Decisão inválida.';
  end if;

  select * into v_req
  from public.deposit_requests
  where id=p_request_id
  for update;

  if v_req.id is null or v_req.status<>'pending' then
    raise exception 'Pedido de depósito não está pendente.';
  end if;

  update public.deposit_requests
  set status=p_decision,reviewed_at=now()
  where id=v_req.id;

  if p_decision='approved' then
    update public.players
    set balance=balance+v_req.amount,updated_at=now()
    where id=v_req.player_id;

    insert into public.transactions(player_id,kind,amount,status,reference_id,note)
    values(v_req.player_id,'deposit',v_req.amount,'completed',v_req.id,
           'Depósito aprovado · deve ser jogado antes de saque');

    insert into public.deposit_wager_requirements(
      deposit_request_id,player_id,original_amount,remaining_amount,status
    ) values (
      v_req.id,v_req.player_id,v_req.amount,v_req.amount,'active'
    );
  end if;

  return jsonb_build_object(
    'ok',true,
    'status',p_decision,
    'request_id',v_req.id,
    'wager_required',case when p_decision='approved' then v_req.amount else 0 end
  );
end;
$$;

create or replace function public.jl_request_withdrawal(p_token text,p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_player public.players%rowtype;
  v_id uuid;
  v_locked numeric:=0;
  v_withdrawable numeric:=0;
begin
  if p_amount is null or p_amount<1 or p_amount>1000000 then
    raise exception 'Valor de saque inválido.';
  end if;

  select * into v_player
  from public.players
  where id=v_player_id
  for update;

  v_locked:=public.jl_deposit_wager_locked(v_player_id);
  v_withdrawable:=greatest(0,v_player.balance-v_locked);

  if p_amount>v_withdrawable then
    insert into public.withdrawal_requests(
      player_id,amount,status,reason,reviewed_at
    ) values (
      v_player_id,round(p_amount,2),'rejected',
      case
        when v_player.balance<p_amount then 'Saldo insuficiente'
        else 'Depósito ainda não foi jogado'
      end,
      now()
    ) returning id into v_id;

    return jsonb_build_object(
      'ok',false,
      'request_id',v_id,
      'status','rejected',
      'message',
        case
          when v_player.balance<p_amount then 'Saque rejeitado automaticamente: saldo insuficiente.'
          else 'Saque bloqueado: parte do saldo vem de depósito que ainda precisa ser jogado.'
        end,
      'balance',v_player.balance,
      'deposit_locked',v_locked,
      'withdrawable_balance',v_withdrawable
    );
  end if;

  update public.players
  set balance=balance-round(p_amount,2),updated_at=now()
  where id=v_player_id;

  insert into public.withdrawal_requests(player_id,amount,status)
  values(v_player_id,round(p_amount,2),'pending')
  returning id into v_id;

  insert into public.transactions(player_id,kind,amount,status,reference_id,note)
  values(v_player_id,'withdrawal',-round(p_amount,2),'pending',v_id,
         'Valor reservado para saque');

  return jsonb_build_object(
    'ok',true,
    'request_id',v_id,
    'status','pending',
    'message','Pedido de saque enviado para autorização.',
    'balance',v_player.balance-round(p_amount,2),
    'deposit_locked',v_locked,
    'withdrawable_balance',v_withdrawable-round(p_amount,2)
  );
end;
$$;

create or replace function public.jl_place_bet(p_token text,p_selected_number integer,p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_player public.players%rowtype;
  v_round public.game_rounds%rowtype;
  v_settings public.game_settings%rowtype;
  v_bet_id uuid;
  v_total_after numeric;
  v_min_after numeric;
  v_bonus_available numeric:=0;
  v_bonus_used numeric:=0;
  v_cash_used numeric:=0;
  v_consumed numeric:=0;
  v_deposit_cleared numeric:=0;
begin
  select * into v_settings from public.game_settings where game_type='number';
  if not v_settings.enabled then raise exception 'Número Lendário está temporariamente desativado.'; end if;
  if p_selected_number<0 or p_selected_number>10 then raise exception 'Escolha um número de 0 a 10.'; end if;
  if p_amount is null or p_amount<>trunc(p_amount) or p_amount<v_settings.min_bet or p_amount>v_settings.max_bet then
    raise exception 'A aposta deve ser um valor inteiro entre % e % MZN.',v_settings.min_bet,v_settings.max_bet;
  end if;

  select * into v_round from public.game_rounds
  where game_type='number' and status='open' and closes_at>now()
  order by opened_at desc limit 1 for update;
  if v_round.id is null then raise exception 'As apostas do Número Lendário estão fechadas neste momento.'; end if;

  select * into v_player from public.players where id=v_player_id for update;
  if v_player.blocked then raise exception 'Esta conta está bloqueada.'; end if;

  v_bonus_available:=public.jl_bonus_available(v_player_id,'number');
  if v_player.balance+v_bonus_available<p_amount then
    raise exception 'Saldo e bónus insuficientes para esta aposta.';
  end if;

  v_bonus_used:=least(p_amount,v_bonus_available);
  v_cash_used:=p_amount-v_bonus_used;

  select coalesce(sum(amount),0)+p_amount into v_total_after
  from public.bets where round_id=v_round.id;

  select min(exposure) into v_min_after
  from (
    select n,coalesce(sum(b.amount),0)+case when n=p_selected_number then p_amount else 0 end exposure
    from generate_series(0,10) n
    left join public.bets b on b.round_id=v_round.id and b.selected_number=n
    group by n
  ) x;

  if v_min_after*v_settings.multiplier>=v_total_after then
    raise exception 'Esta aposta atingiria o limite de segurança da rodada. Escolha outro número ou aguarde a próxima rodada.';
  end if;

  insert into public.bets(round_id,player_id,selected_number,amount,cash_amount,bonus_amount)
  values(v_round.id,v_player_id,p_selected_number,p_amount,v_cash_used,v_bonus_used)
  returning id into v_bet_id;

  if v_bonus_used>0 then
    v_consumed:=public.jl_consume_bonus(v_player_id,'number',v_bonus_used,v_bet_id);
    if v_consumed<>v_bonus_used then raise exception 'Não foi possível reservar o bónus desta aposta.'; end if;
  end if;

  if v_cash_used>0 then
    update public.players set balance=balance-v_cash_used,updated_at=now() where id=v_player_id;
    v_deposit_cleared:=public.jl_apply_cash_wager(v_player_id,v_cash_used,'number_bet',v_bet_id);

    insert into public.transactions(player_id,kind,amount,status,reference_id,note)
    values(v_player_id,'bet',-v_cash_used,'completed',v_bet_id,
      'Aposta no Número Lendário · '||v_bonus_used||' MZN de bónus · '||
      v_deposit_cleared||' MZN de depósito liberado');
  end if;

  return jsonb_build_object(
    'ok',true,'bet_id',v_bet_id,'round_no',v_round.round_no,
    'selected_number',p_selected_number,'amount',p_amount,
    'cash_used',v_cash_used,'bonus_used',v_bonus_used,
    'deposit_wager_cleared',v_deposit_cleared,
    'balance',v_player.balance-v_cash_used,
    'deposit_locked',public.jl_deposit_wager_locked(v_player_id),
    'bonus_remaining',public.jl_bonus_available(v_player_id,'number')
  );
end;
$$;

create or replace function public.jl_place_pair_bet(p_token text,p_number_a integer,p_number_b integer,p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_player public.players%rowtype;
  v_round public.game_rounds%rowtype;
  v_settings public.game_settings%rowtype;
  v_bet_id uuid;
  v_a integer;
  v_b integer;
  v_total_after numeric;
  v_min_after numeric;
  v_bonus_available numeric:=0;
  v_bonus_used numeric:=0;
  v_cash_used numeric:=0;
  v_consumed numeric:=0;
  v_deposit_cleared numeric:=0;
begin
  select * into v_settings from public.game_settings where game_type='pair';
  if not v_settings.enabled then raise exception 'Dupla Lendária está temporariamente desativada.'; end if;
  if p_number_a is null or p_number_b is null then raise exception 'Escolha dois números.'; end if;
  if p_number_a<0 or p_number_a>10 or p_number_b<0 or p_number_b>10 then raise exception 'Escolha dois números entre 0 e 10.'; end if;
  if p_number_a=p_number_b then raise exception 'Escolha dois números diferentes.'; end if;

  v_a:=least(p_number_a,p_number_b);
  v_b:=greatest(p_number_a,p_number_b);

  if p_amount is null or p_amount<>trunc(p_amount) or p_amount<v_settings.min_bet or p_amount>v_settings.max_bet then
    raise exception 'A aposta deve ser um valor inteiro entre % e % MZN.',v_settings.min_bet,v_settings.max_bet;
  end if;

  select * into v_round from public.game_rounds
  where game_type='pair' and status='open' and closes_at>now()
  order by opened_at desc limit 1 for update;
  if v_round.id is null then raise exception 'As apostas da Dupla Lendária estão fechadas neste momento.'; end if;

  select * into v_player from public.players where id=v_player_id for update;
  if v_player.blocked then raise exception 'Esta conta está bloqueada.'; end if;

  v_bonus_available:=public.jl_bonus_available(v_player_id,'pair');
  if v_player.balance+v_bonus_available<p_amount then
    raise exception 'Saldo e bónus insuficientes para esta aposta.';
  end if;

  v_bonus_used:=least(p_amount,v_bonus_available);
  v_cash_used:=p_amount-v_bonus_used;

  select coalesce(sum(amount),0)+p_amount into v_total_after
  from public.pair_bets where round_id=v_round.id;

  select min(exposure) into v_min_after
  from (
    select a,b,coalesce(sum(pb.amount),0)+case when a=v_a and b=v_b then p_amount else 0 end exposure
    from generate_series(0,10) a
    cross join generate_series(0,10) b
    left join public.pair_bets pb on pb.round_id=v_round.id and pb.number_a=a and pb.number_b=b
    where a<b
    group by a,b
  ) x;

  if v_min_after*v_settings.multiplier>=v_total_after then
    raise exception 'Esta aposta atingiria o limite de segurança da rodada. Escolha outra combinação ou aguarde a próxima rodada.';
  end if;

  insert into public.pair_bets(round_id,player_id,number_a,number_b,amount,cash_amount,bonus_amount)
  values(v_round.id,v_player_id,v_a,v_b,p_amount,v_cash_used,v_bonus_used)
  returning id into v_bet_id;

  if v_bonus_used>0 then
    v_consumed:=public.jl_consume_bonus(v_player_id,'pair',v_bonus_used,v_bet_id);
    if v_consumed<>v_bonus_used then raise exception 'Não foi possível reservar o bónus desta aposta.'; end if;
  end if;

  if v_cash_used>0 then
    update public.players set balance=balance-v_cash_used,updated_at=now() where id=v_player_id;
    v_deposit_cleared:=public.jl_apply_cash_wager(v_player_id,v_cash_used,'pair_bet',v_bet_id);

    insert into public.transactions(player_id,kind,amount,status,reference_id,note)
    values(v_player_id,'bet',-v_cash_used,'completed',v_bet_id,
      'Aposta Dupla Lendária '||v_a||'+'||v_b||' · '||v_bonus_used||
      ' MZN de bónus · '||v_deposit_cleared||' MZN de depósito liberado');
  end if;

  return jsonb_build_object(
    'ok',true,'bet_id',v_bet_id,'round_no',v_round.round_no,
    'number_a',v_a,'number_b',v_b,'amount',p_amount,
    'cash_used',v_cash_used,'bonus_used',v_bonus_used,
    'deposit_wager_cleared',v_deposit_cleared,
    'balance',v_player.balance-v_cash_used,
    'deposit_locked',public.jl_deposit_wager_locked(v_player_id),
    'bonus_remaining',public.jl_bonus_available(v_player_id,'pair')
  );
end;
$$;

create or replace function public.jl_ludo_commit_stake(p_token text,p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  pl public.players%rowtype;
  rp public.ludo_room_players%rowtype;
  cleared numeric:=0;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.id is null or r.status<>'funding' then raise exception 'A sala ainda não está na fase de aposta.'; end if;
  if r.action_deadline<=now() then raise exception 'Tempo para confirmar a aposta expirou.'; end if;

  select * into rp
  from public.ludo_room_players
  where room_id=p_room and player_id=me and status<>'left'
  for update;

  if rp.player_id is null or rp.accepted_rules_version<>r.rules_version then
    raise exception 'Aceite primeiro as regras atuais.';
  end if;

  if rp.stake_paid then return public.jl_ludo_room_state(p_token,p_room); end if;

  select * into pl from public.players where id=me for update;
  if pl.blocked then raise exception 'Conta bloqueada.'; end if;
  if pl.balance<r.bet_amount then raise exception 'Saldo insuficiente para a aposta desta sala.'; end if;

  update public.players set balance=balance-r.bet_amount,updated_at=now() where id=me;
  cleared:=public.jl_apply_cash_wager(me,r.bet_amount,'ludo_stake',p_room);

  update public.ludo_room_players
  set stake_paid=true,stake_amount=r.bet_amount
  where room_id=p_room and player_id=me;

  update public.ludo_rooms
  set pot=pot+r.bet_amount,updated_at=now()
  where id=p_room;

  insert into public.transactions(player_id,kind,amount,status,reference_id,note)
  values(me,'ludo_stake',-r.bet_amount,'completed',p_room,
         'Aposta Ludo '||r.code||' · '||cleared||' MZN de depósito liberado');

  perform public.jl_ludo_event(
    p_room,me,'stake_committed',
    jsonb_build_object('amount',r.bet_amount,'deposit_wager_cleared',cleared)
  );

  if not exists(
    select 1
    from public.ludo_room_players
    where room_id=p_room and status<>'left' and not stake_paid
  ) then
    perform public.jl_ludo_start_game(p_room);
  end if;

  return public.jl_ludo_room_state(p_token,p_room);
end;
$$;

create or replace function public.jl_ludo_reenter(p_token text,p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  rp public.ludo_room_players%rowtype;
  pl public.players%rowtype;
  amt numeric;
  cleared numeric:=0;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  select * into rp from public.ludo_room_players where room_id=p_room and player_id=me for update;

  if r.status<>'playing' or rp.status<>'reentry' then
    raise exception 'Reentrada indisponível.';
  end if;

  amt:=(r.rules->>'reentry_amount')::numeric;
  select * into pl from public.players where id=me for update;
  if pl.balance<amt then raise exception 'Saldo insuficiente para reentrar.'; end if;

  update public.players set balance=balance-amt,updated_at=now() where id=me;
  cleared:=public.jl_apply_cash_wager(me,amt,'ludo_reentry',p_room);

  update public.ludo_rooms set pot=pot+amt,updated_at=now() where id=p_room;
  update public.ludo_room_players
  set status='active',reentry_deadline=null
  where room_id=p_room and player_id=me;

  insert into public.transactions(player_id,kind,amount,status,reference_id,note)
  values(me,'ludo_reentry',-amt,'completed',p_room,
         'Reentrada no Ludo '||r.code||' · '||cleared||' MZN de depósito liberado');

  perform public.jl_ludo_event(
    p_room,me,'player_reentered',
    jsonb_build_object(
      'amount',amt,
      'late_reconnect_allowed',true,
      'deposit_wager_cleared',cleared
    )
  );

  return public.jl_ludo_room_state(p_token,p_room);
end;
$$;

create or replace function public.jl_ludo_refund_room(
  p_room uuid,
  p_note text default 'Reembolso Ludo'
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  x record;
  restored numeric;
begin
  for x in
    select *
    from public.ludo_room_players
    where room_id=p_room and stake_paid
  loop
    update public.players
    set balance=balance+x.stake_amount,updated_at=now()
    where id=x.player_id;

    restored:=public.jl_reverse_cash_wager(
      x.player_id,'ludo_stake',p_room
    );

    insert into public.transactions(player_id,kind,amount,status,reference_id,note)
    values(
      x.player_id,'ludo_refund',x.stake_amount,'completed',p_room,
      p_note||' · '||restored||' MZN voltaram a ficar bloqueados até serem jogados'
    );
  end loop;

  update public.ludo_room_players
  set stake_paid=false,stake_amount=0
  where room_id=p_room;

  update public.ludo_rooms
  set pot=0,updated_at=now()
  where id=p_room;
end;
$$;

create or replace function public.jl_player_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_player public.players%rowtype;
  v_public jsonb;
  v_bets jsonb;
  v_pair_bets jsonb;
  v_deposits jsonb;
  v_withdrawals jsonb;
  v_bonus_total numeric;
  v_bonus_number numeric;
  v_bonus_pair numeric;
  v_bonus_grants jsonb;
  v_deposit_locked numeric;
  v_withdrawable numeric;
begin
  select * into v_player from public.players where id=v_player_id;
  select public.jl_public_state() into v_public;

  v_deposit_locked:=public.jl_deposit_wager_locked(v_player_id);
  v_withdrawable:=greatest(0,v_player.balance-v_deposit_locked);

  select
    coalesce(sum(remaining_amount) filter(where status='active'),0),
    coalesce(sum(remaining_amount) filter(where status='active' and game_scope in ('number','both')),0),
    coalesce(sum(remaining_amount) filter(where status='active' and game_scope in ('pair','both')),0)
  into v_bonus_total,v_bonus_number,v_bonus_pair
  from public.bonus_grants where player_id=v_player_id;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_bonus_grants
  from (
    select id,game_scope,bonus_type,original_amount,remaining_amount,played_amount,status,note,created_at
    from public.bonus_grants
    where player_id=v_player_id
    order by created_at desc
    limit 30
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_bets
  from (
    select b.id,b.selected_number,b.amount,b.cash_amount,b.bonus_amount,b.won,b.payout,b.created_at,r.round_no,
      case when r.status='published' then r.drawn_number else null end drawn_number,r.status round_status
    from public.bets b join public.game_rounds r on r.id=b.round_id
    where b.player_id=v_player_id order by b.created_at desc limit 30
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_pair_bets
  from (
    select pb.id,pb.number_a,pb.number_b,pb.amount,pb.cash_amount,pb.bonus_amount,pb.won,pb.payout,pb.created_at,r.round_no,
      case when r.status='published' then r.pair_drawn_a else null end pair_drawn_a,
      case when r.status='published' then r.pair_drawn_b else null end pair_drawn_b,
      r.status round_status
    from public.pair_bets pb join public.game_rounds r on r.id=pb.round_id
    where pb.player_id=v_player_id order by pb.created_at desc limit 30
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_deposits
  from (
    select d.id,d.amount,d.note,d.status,d.created_at,d.reviewed_at,
           coalesce(w.remaining_amount,0) wager_remaining
    from public.deposit_requests d
    left join public.deposit_wager_requirements w on w.deposit_request_id=d.id
    where d.player_id=v_player_id
    order by d.created_at desc
    limit 20
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_withdrawals
  from (
    select id,amount,status,reason,created_at,reviewed_at
    from public.withdrawal_requests
    where player_id=v_player_id
    order by created_at desc
    limit 20
  ) x;

  return v_public || jsonb_build_object(
    'player',jsonb_build_object(
      'id',v_player.id,
      'name',v_player.name,
      'phone',v_player.phone,
      'balance',v_player.balance,
      'withdrawable_balance',v_withdrawable,
      'deposit_locked',v_deposit_locked,
      'bonus_balance',v_bonus_total,
      'blocked',v_player.blocked
    ),
    'deposit_wager',jsonb_build_object(
      'locked',v_deposit_locked,
      'withdrawable',v_withdrawable
    ),
    'bonus',jsonb_build_object(
      'total',v_bonus_total,'number',v_bonus_number,'pair',v_bonus_pair,'grants',v_bonus_grants
    ),
    'bets',v_bets,
    'pair_bets',v_pair_bets,
    'deposits',v_deposits,
    'withdrawals',v_withdrawals
  );
end;
$$;

create or replace function public.jl_admin_dashboard(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_number jsonb;
  v_pair jsonb;
  v_deposits jsonb;
  v_withdrawals jsonb;
  v_players jsonb;
begin
  perform public.jl_require_admin(p_token);
  perform public.jl_process_game_engine();

  v_number:=public.jl_admin_game_snapshot('number');
  v_pair:=public.jl_admin_game_snapshot('pair');

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb)
  into v_deposits
  from (
    select d.id,d.amount,d.note,d.status,d.created_at,p.name,p.phone
    from public.deposit_requests d
    join public.players p on p.id=d.player_id
    where d.status='pending'
    order by d.created_at desc
    limit 100
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb)
  into v_withdrawals
  from (
    select w.id,w.amount,w.status,w.reason,w.created_at,p.name,p.phone,
           public.jl_deposit_wager_locked(w.player_id) deposit_locked,
           greatest(0,p.balance-public.jl_deposit_wager_locked(w.player_id)) withdrawable_balance
    from public.withdrawal_requests w
    join public.players p on p.id=w.player_id
    where w.status='pending'
    order by w.created_at desc
    limit 100
  ) x;

  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb)
  into v_players
  from (
    select p.id,p.name,p.phone,p.balance,p.blocked,p.created_at,
           public.jl_deposit_wager_locked(p.id) deposit_locked,
           greatest(0,p.balance-public.jl_deposit_wager_locked(p.id)) withdrawable_balance
    from public.players p
    order by p.created_at desc
    limit 200
  ) x;

  return jsonb_build_object(
    'server_time',now(),
    'games',jsonb_build_object('number',v_number,'pair',v_pair),
    'pending_deposits',v_deposits,
    'pending_withdrawals',v_withdrawals,
    'players',v_players
  );
end;
$$;

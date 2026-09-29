-- Aviator Lendario: apostas, voo, cash-out e extensao visual precomposta.
-- A extensao visual nunca cria nova responsabilidade financeira: so e ativada depois de zero apostas ACTIVE.

alter table public.jl_aviator_rounds
  add column if not exists visual_target numeric(18,6),
  add column if not exists visual_seed_commit text,
  add column if not exists visual_seed_reveal text,
  add column if not exists effective_target numeric(18,6);

alter table public.transactions drop constraint if exists transactions_kind_check;
alter table public.transactions add constraint transactions_kind_check
check (kind in ('deposit','withdrawal','withdrawal_refund','bet','payout','adjustment','aviator_bet','aviator_payout'));

create or replace function public.jl_aviator_multiplier(p_started_at timestamptz, p_at timestamptz default now())
returns numeric language sql immutable
as $$
  select greatest(1::numeric, round(power(1.06::numeric, greatest(0, extract(epoch from (p_at-p_started_at))))::numeric, 6));
$$;

create or replace function public.jl_aviator_place_bet(p_token text, p_amount numeric)
returns jsonb language plpgsql security definer set search_path=public,extensions
as $$
declare v_player_id uuid:=public.jl_player_id(p_token);
declare v_player public.players%rowtype;
declare v_round public.jl_aviator_rounds%rowtype;
declare v_bet public.jl_aviator_bets%rowtype;
begin
  if p_amount is null or p_amount < 1 or p_amount > 1000000 then raise exception 'Valor de aposta invalido.'; end if;
  select * into v_round from public.jl_aviator_rounds where status='OPEN' order by id desc limit 1 for update;
  if v_round.id is null then raise exception 'Nao ha rodada Aviator aberta.'; end if;
  select * into v_player from public.players where id=v_player_id for update;
  if v_player.blocked then raise exception 'Jogador bloqueado.'; end if;
  if v_player.balance < p_amount then raise exception 'Saldo insuficiente.'; end if;

  update public.players set balance=round(balance-p_amount,2),updated_at=now() where id=v_player_id;
  insert into public.jl_aviator_bets(round_id,player_id,stake)
  values(v_round.id,v_player_id,round(p_amount,2)) returning * into v_bet;
  insert into public.transactions(player_id,kind,amount,status,note)
  values(v_player_id,'aviator_bet',-round(p_amount,2),'completed','Aposta Aviator rodada '||v_round.id);
  insert into public.audit_log(action,details)
  values('aviator.bet_placed',jsonb_build_object('roundId',v_round.id,'betId',v_bet.id,'playerId',v_player_id,'stake',v_bet.stake));
  return jsonb_build_object('ok',true,'bet_id',v_bet.id,'round_id',v_round.id,'stake',v_bet.stake,'balance',v_player.balance-round(p_amount,2));
end $$;

create or replace function public.jl_aviator_lock_round(p_round_id bigint)
returns public.jl_aviator_rounds language plpgsql security definer set search_path=public,extensions
as $$
declare v_round public.jl_aviator_rounds; v_bank public.jl_aviator_bank; v_total numeric; v_seed text; v_u numeric; v_visual numeric;
begin
  select * into v_round from public.jl_aviator_rounds where id=p_round_id for update;
  if not found or v_round.status<>'OPEN' then raise exception 'Rodada nao esta OPEN'; end if;
  select * into v_bank from public.jl_aviator_bank where id=true for update;
  select coalesce(sum(stake),0) into v_total from public.jl_aviator_bets where round_id=p_round_id and status='ACTIVE';

  v_seed:=encode(extensions.gen_random_bytes(32),'hex');
  v_u:=('x'||substr(encode(extensions.digest(v_seed,'sha256'),'hex'),1,8))::bit(32)::bigint / 4294967295.0;
  v_visual:=round(5 + (130.7*v_u),6);

  update public.jl_aviator_rounds set status='LOCKED',locked_at=now(),
    bank_balance_snapshot=v_bank.balance,risk_reserve=round(v_bank.balance*v_bank.exposure_ratio,2),
    total_staked=v_total,financial_ceiling=public.jl_aviator_financial_ceiling(v_bank.balance,v_total,v_bank.exposure_ratio),
    visual_target=v_visual,visual_seed_commit=encode(extensions.digest(v_seed,'sha256'),'hex'),
    visual_seed_reveal=v_seed,
    effective_target=case when v_total=0 then v_visual else public.jl_aviator_financial_ceiling(v_bank.balance,v_total,v_bank.exposure_ratio) end,
    visual_extension=(v_total=0)
  where id=p_round_id returning * into v_round;
  return v_round;
end $$;

create or replace function public.jl_aviator_start_round(p_round_id bigint)
returns public.jl_aviator_rounds language plpgsql security definer set search_path=public
as $$
declare v public.jl_aviator_rounds;
begin
 select * into v from public.jl_aviator_rounds where id=p_round_id for update;
 if v.id is null or v.status<>'LOCKED' then raise exception 'Rodada nao esta LOCKED'; end if;
 update public.jl_aviator_rounds set status='FLYING',started_at=clock_timestamp() where id=p_round_id returning * into v;
 return v;
end $$;

create or replace function public.jl_aviator_cashout(p_token text,p_bet_id bigint)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_player_id uuid:=public.jl_player_id(p_token); v_bet public.jl_aviator_bets; v_round public.jl_aviator_rounds; v_m numeric; v_payout numeric; v_active int;
begin
 select * into v_bet from public.jl_aviator_bets where id=p_bet_id for update;
 if v_bet.id is null or v_bet.player_id<>v_player_id then raise exception 'Aposta nao encontrada.'; end if;
 if v_bet.status<>'ACTIVE' then raise exception 'Aposta ja liquidada.'; end if;
 select * into v_round from public.jl_aviator_rounds where id=v_bet.round_id for update;
 if v_round.status<>'FLYING' or v_round.started_at is null then raise exception 'Voo nao esta ativo.'; end if;
 v_m:=public.jl_aviator_multiplier(v_round.started_at,clock_timestamp());
 if v_m>=coalesce(v_round.effective_target,v_round.financial_ceiling) then raise exception 'Crash ja atingido.'; end if;
 v_payout:=round(v_bet.stake*v_m,2);
 update public.jl_aviator_bets set status='CASHED_OUT',cashout_multiplier=v_m,payout=v_payout,cashed_out_at=now() where id=v_bet.id;
 update public.players set balance=round(balance+v_payout,2),updated_at=now() where id=v_player_id;
 update public.jl_aviator_bank set balance=greatest(0,round(balance-(v_payout-v_bet.stake),2)),updated_at=now() where id=true;
 insert into public.transactions(player_id,kind,amount,status,note) values(v_player_id,'aviator_payout',v_payout,'completed','Cash-out Aviator '||v_m||'x');
 select count(*) into v_active from public.jl_aviator_bets where round_id=v_round.id and status='ACTIVE';
 if v_active=0 and v_m<v_round.financial_ceiling then
   update public.jl_aviator_rounds set visual_extension=true,zero_exposure_at_multiplier=v_m,
     effective_target=greatest(v_m,v_round.visual_target)
   where id=v_round.id;
 end if;
 insert into public.audit_log(action,details) values('aviator.cashout',jsonb_build_object('roundId',v_round.id,'betId',v_bet.id,'playerId',v_player_id,'multiplier',v_m,'payout',v_payout));
 return jsonb_build_object('ok',true,'multiplier',v_m,'payout',v_payout);
end $$;

create or replace function public.jl_aviator_tick(p_round_id bigint)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v public.jl_aviator_rounds; v_m numeric; v_lost numeric;
begin
 select * into v from public.jl_aviator_rounds where id=p_round_id for update;
 if v.id is null then raise exception 'Rodada nao encontrada'; end if;
 if v.status<>'FLYING' then return jsonb_build_object('status',v.status,'round_id',v.id); end if;
 v_m:=public.jl_aviator_multiplier(v.started_at,clock_timestamp());
 if v_m<coalesce(v.effective_target,v.financial_ceiling,v.visual_target) then
   return jsonb_build_object('status','FLYING','round_id',v.id,'multiplier',v_m);
 end if;
 update public.jl_aviator_bets set status='LOST',payout=0 where round_id=v.id and status='ACTIVE';
 select coalesce(sum(stake),0) into v_lost from public.jl_aviator_bets where round_id=v.id and status='LOST';
 update public.jl_aviator_bank set balance=round(balance+v_lost,2),updated_at=now() where id=true;
 update public.jl_aviator_rounds set status='CRASHED',crashed_at=clock_timestamp(),crash_multiplier=coalesce(effective_target,financial_ceiling,visual_target) where id=v.id returning * into v;
 insert into public.audit_log(action,details) values('aviator.crashed',jsonb_build_object('roundId',v.id,'crashMultiplier',v.crash_multiplier,'lostStakes',v_lost,'visualExtension',v.visual_extension));
 return jsonb_build_object('status','CRASHED','round_id',v.id,'crash_multiplier',v.crash_multiplier);
end $$;

revoke all on function public.jl_aviator_place_bet(text,numeric) from public;
revoke all on function public.jl_aviator_cashout(text,bigint) from public;
grant execute on function public.jl_aviator_place_bet(text,numeric) to anon,authenticated;
grant execute on function public.jl_aviator_cashout(text,bigint) to anon,authenticated;
revoke all on function public.jl_aviator_start_round(bigint) from public,anon,authenticated;
revoke all on function public.jl_aviator_tick(bigint) from public,anon,authenticated;
grant execute on function public.jl_aviator_start_round(bigint) to service_role;
grant execute on function public.jl_aviator_tick(bigint) to service_role;

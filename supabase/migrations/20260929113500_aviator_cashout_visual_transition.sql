-- Aviator: cash-out idempotente com transicao automatica para voo visual.
create or replace function public.jl_aviator_cashout(p_token text,p_bet_id bigint)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_player_id uuid:=public.jl_player_id(p_token); v_bet public.jl_aviator_bets; v_round public.jl_aviator_rounds;
v_m numeric; v_payout numeric; v_profit numeric; v_active int; v_tx uuid:=gen_random_uuid(); v_bank public.jl_aviator_bank; v_visual numeric;
begin
 select * into v_bet from public.jl_aviator_bets where id=p_bet_id for update;
 if v_bet.id is null or v_bet.player_id<>v_player_id then raise exception 'Aposta nao encontrada.'; end if;
 if v_bet.status='CASHED_OUT' then return jsonb_build_object('ok',true,'already_processed',true,'multiplier',v_bet.cashout_multiplier,'payout',v_bet.payout); end if;
 if v_bet.status<>'ACTIVE' then raise exception 'Aposta ja liquidada.'; end if;
 select * into v_round from public.jl_aviator_rounds where id=v_bet.round_id for update;
 if v_round.status<>'FLYING' then raise exception 'Voo nao esta ativo.'; end if;
 v_m:=public.jl_aviator_multiplier(v_round.started_at,clock_timestamp());
 if v_m>=coalesce(v_round.effective_target,v_round.financial_ceiling,v_round.visual_target) then raise exception 'Crash ja atingido.'; end if;
 v_payout:=round(v_bet.stake*v_m,2); v_profit:=greatest(0,v_payout-v_bet.stake);
 select * into v_bank from public.jl_aviator_bank where id=true for update;
 if v_bank.balance<v_profit then raise exception 'Reserva da banca inconsistente.'; end if;
 update public.jl_aviator_bets set status='CASHED_OUT',cashout_multiplier=v_m,payout=v_payout,cashed_out_at=now(),payout_transaction_id=v_tx where id=v_bet.id;
 update public.players set balance=round(balance+v_payout,2),updated_at=now() where id=v_player_id;
 update public.jl_aviator_bank set balance=round(balance-v_profit,2),updated_at=now() where id=true;
 insert into public.transactions(id,player_id,kind,amount,status,note) values(v_tx,v_player_id,'aviator_payout',v_payout,'completed','Cash-out Aviator '||v_m||'x');
 select count(*) into v_active from public.jl_aviator_bets where round_id=v_round.id and status='ACTIVE';
 if v_active=0 and not v_round.visual_extension then v_visual:=public.jl_aviator_set_visual_target(v_round.id,v_m); end if;
 insert into public.audit_log(action,details) values('aviator.cashout',jsonb_build_object('roundId',v_round.id,'betId',v_bet.id,'multiplier',v_m,'payout',v_payout,'visualTarget',v_visual));
 return jsonb_build_object('ok',true,'already_processed',false,'multiplier',v_m,'payout',v_payout);
end $$;

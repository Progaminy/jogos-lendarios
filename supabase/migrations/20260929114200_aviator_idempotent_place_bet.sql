-- Aviator: API idempotente de aposta para retries de rede.
create or replace function public.jl_aviator_place_bet(p_token text,p_amount numeric,p_request_key text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_player_id uuid:=public.jl_player_id(p_token); v_player public.players; v_round public.jl_aviator_rounds; v_bet public.jl_aviator_bets;
begin
 if p_request_key is null or length(trim(p_request_key))<8 or length(p_request_key)>100 then raise exception 'Chave da aposta invalida.'; end if;
 select * into v_bet from public.jl_aviator_bets where player_id=v_player_id and request_key=p_request_key;
 if v_bet.id is not null then return jsonb_build_object('ok',true,'already_processed',true,'bet_id',v_bet.id,'round_id',v_bet.round_id,'stake',v_bet.stake); end if;
 if p_amount is null or p_amount<1 or p_amount>1000000 then raise exception 'Valor de aposta invalido.'; end if;
 select * into v_round from public.jl_aviator_rounds where status='OPEN' order by id desc limit 1 for update;
 if v_round.id is null then raise exception 'Nao ha rodada Aviator aberta.'; end if;
 select * into v_player from public.players where id=v_player_id for update;
 if v_player.blocked then raise exception 'Jogador bloqueado.'; end if;
 if v_player.balance<p_amount then raise exception 'Saldo insuficiente.'; end if;
 update public.players set balance=round(balance-p_amount,2),updated_at=now() where id=v_player_id;
 insert into public.jl_aviator_bets(round_id,player_id,stake,request_key) values(v_round.id,v_player_id,round(p_amount,2),p_request_key) returning * into v_bet;
 insert into public.transactions(player_id,kind,amount,status,note) values(v_player_id,'aviator_bet',-round(p_amount,2),'completed','Aposta Aviator rodada '||v_round.id);
 return jsonb_build_object('ok',true,'already_processed',false,'bet_id',v_bet.id,'round_id',v_round.id,'stake',v_bet.stake,'balance',v_player.balance-round(p_amount,2));
end $$;
revoke execute on function public.jl_aviator_place_bet(text,numeric) from anon,authenticated;
grant execute on function public.jl_aviator_place_bet(text,numeric,text) to anon,authenticated;

-- Regressoes financeiras Aviator. Execute em ambiente de teste/transacao rollback.
begin;
do $$
declare p uuid:=gen_random_uuid(); tok text:='aviator-regression-token'; rid bigint; b jsonb; co jsonb; co2 jsonb; rr public.jl_aviator_rounds; bal numeric;
begin
 if public.jl_aviator_financial_ceiling(200000,100000,.5)<>2 then raise exception '200k/100k != 2x'; end if;
 if public.jl_aviator_financial_ceiling(100000,100000,.5)<>1.5 then raise exception '100k/100k != 1.5x'; end if;
 if public.jl_aviator_financial_ceiling(100000,200000,.5)<>1.25 then raise exception '100k/200k != 1.25x'; end if;
 if public.jl_aviator_financial_ceiling(0,100,.5)<>1 then raise exception 'zero bank != 1x'; end if;
 if public.jl_aviator_financial_ceiling(100000,0,.5) is not null then raise exception 'zero stakes must be visual-only'; end if;
 insert into public.players(id,name,phone,pin_hash,balance) values(p,'AVIATOR REGRESSION','__aviator_reg__'||substr(p::text,1,8),'x',300000);
 insert into public.player_sessions(player_id,token_hash,expires_at) values(p,public.jl_token_hash(tok),now()+interval '1 hour');
 update public.jl_aviator_bank set balance=100000 where id=true;
 update public.jl_aviator_rounds set status='CANCELLED' where status in ('OPEN','LOCKED','FLYING');
 insert into public.jl_aviator_rounds(status,betting_closes_at) values('OPEN',now()+interval '1 minute') returning id into rid;
 b:=public.jl_aviator_place_bet(tok,200000,'aviator-regression-request');
 rr:=public.jl_aviator_lock_round(rid);
 if rr.risk_reserve<>50000 or rr.financial_ceiling<>1.25 then raise exception 'frozen reserve/ceiling wrong'; end if;
 update public.jl_aviator_rounds set status='FLYING',started_at=clock_timestamp()-interval '.5 second' where id=rid;
 co:=public.jl_aviator_cashout(tok,(b->>'bet_id')::bigint);
 co2:=public.jl_aviator_cashout(tok,(b->>'bet_id')::bigint);
 if (co2->>'already_processed')::boolean is not true then raise exception 'cashout retry duplicated'; end if;
 select balance into bal from public.jl_aviator_bank where id=true;
 if bal<0 then raise exception 'bank became negative'; end if;
 select * into rr from public.jl_aviator_rounds where id=rid;
 if not rr.visual_extension or rr.effective_target<5 or rr.effective_target>135.7 then raise exception 'visual extension invalid'; end if;
end $$;
rollback;
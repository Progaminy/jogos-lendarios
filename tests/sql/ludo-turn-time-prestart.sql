-- Ludo Lendário — regressão do tempo configurável e pré-início sem prazo.
-- Não fabrica sessão/login; testa o núcleo diretamente e termina em ROLLBACK.

begin;

do $$
declare
  a uuid:=extensions.gen_random_uuid();
  b uuid:=extensions.gen_random_uuid();
  rid uuid:=extensions.gen_random_uuid();
  rr jsonb;
  r public.ludo_rooms%rowtype;
  secs integer;
  invalid_blocked boolean:=false;
begin
  insert into public.players(id,name,phone,pin_hash,balance)
  values
    (a,'Ludo Teste A','LT-A-'||substr(a::text,1,8),'not-used',0),
    (b,'Ludo Teste B','LT-B-'||substr(b::text,1,8),'not-used',0);

  foreach secs in array array[10,15,20,25,30] loop
    rr:=public.jl_ludo_rules(jsonb_build_object('turn_seconds',secs),10);
    if (rr->>'turn_seconds')::int<>secs
       or (rr->>'move_seconds')::int<>secs then
      raise exception 'LUDO: tempo % não foi preservado',secs;
    end if;
  end loop;

  begin
    perform public.jl_ludo_rules('{"turn_seconds":60}'::jsonb,10);
  exception when others then
    if sqlerrm ilike '%10, 15, 20, 25 ou 30%' then
      invalid_blocked:=true;
    else
      raise;
    end if;
  end;

  if not invalid_blocked then
    raise exception 'LUDO: tempo inválido de 60 s foi aceite';
  end if;

  rr:=public.jl_ludo_rules('{"turn_seconds":15}'::jsonb,10);

  insert into public.ludo_rooms(
    id,code,host_id,player_count,pawn_count,mode,bet_amount,pot,is_public,
    rules,rules_version,status,action_deadline
  ) values(
    rid,'TST-LUDO-'||substr(replace(rid::text,'-',''),1,6),
    a,2,4,'solo',10,20,false,rr,1,'funding',now()+interval '60 seconds'
  );

  insert into public.ludo_room_players(
    room_id,player_id,seat,color,accepted_rules_version,
    stake_paid,stake_amount,status
  ) values
    (rid,a,1,'red',1,true,10,'active'),
    (rid,b,2,'yellow',1,true,10,'active');

  perform public.jl_ludo_start_game(rid);

  select * into r from public.ludo_rooms where id=rid;

  if r.status<>'playing' then
    raise exception 'LUDO: start_game não colocou playing';
  end if;
  if r.started_at is not null then
    raise exception 'LUDO: started_at foi definido antes do primeiro dado';
  end if;
  if r.action_deadline is not null then
    raise exception 'LUDO: cronómetro iniciou antes do primeiro dado';
  end if;
  if r.turn_phase<>'roll' then
    raise exception 'LUDO: fase inicial não é roll';
  end if;
  if r.current_player_id<>a then
    raise exception 'LUDO: primeiro jogador incorreto';
  end if;
  if (r.rules->>'turn_seconds')::int<>15
     or (r.rules->>'move_seconds')::int<>15 then
    raise exception 'LUDO: sala perdeu o tempo de 15 s';
  end if;
  if (select count(*) from public.ludo_tokens where room_id=rid)<>8 then
    raise exception 'LUDO: esperado 8 peões para 2 jogadores';
  end if;
end
$$;

rollback;

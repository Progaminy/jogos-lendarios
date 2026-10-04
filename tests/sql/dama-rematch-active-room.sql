-- Regressão: uma revanche não pode sequestrar jogador que já entrou noutra sala.
-- Tudo roda em transação e termina em ROLLBACK.

begin;

do $$
declare
  pa uuid:=extensions.gen_random_uuid();
  pb uuid:=extensions.gen_random_uuid();
  pc uuid:=extensions.gen_random_uuid();
  ta text:='dama-rematch-a-'||replace(extensions.gen_random_uuid()::text,'-','');
  tb text:='dama-rematch-b-'||replace(extensions.gen_random_uuid()::text,'-','');
  tc text:='dama-rematch-c-'||replace(extensions.gen_random_uuid()::text,'-','');
  s jsonb;
  old_room uuid;
  other_room uuid;
  code text;
  route text;
  failed_as_expected boolean:=false;
begin
  insert into public.players(id,name,phone,pin_hash,balance)
  values
    (pa,'Rematch A','RM-A-'||substr(pa::text,1,8),extensions.crypt('1234',extensions.gen_salt('bf')),100),
    (pb,'Rematch B','RM-B-'||substr(pb::text,1,8),extensions.crypt('1234',extensions.gen_salt('bf')),100),
    (pc,'Rematch C','RM-C-'||substr(pc::text,1,8),extensions.crypt('1234',extensions.gen_salt('bf')),100);

  insert into public.player_sessions(player_id,token_hash,expires_at)
  values
    (pa,public.jl_token_hash(ta),now()+interval '1 hour'),
    (pb,public.jl_token_hash(tb),now()+interval '1 hour'),
    (pc,public.jl_token_hash(tc),now()+interval '1 hour');

  -- A e B terminam uma partida válida.
  s:=public.jl_dama_create_room(ta,10,120,'white','host',false);
  old_room:=(s->'room'->>'id')::uuid;
  code:=s->'room'->>'code';
  perform public.jl_dama_join_room(tb,code);
  perform public.jl_dama_accept_settings(tb,old_room,true);
  perform public.jl_dama_commit_stake(ta,old_room);
  perform public.jl_dama_commit_stake(tb,old_room);
  s:=public.jl_dama_room_state(ta,old_room);
  route:=s->'legal_moves'->0->>'route_id';
  perform public.jl_dama_move(ta,old_room,route);
  perform public.jl_dama_forfeit(tb,old_room);

  if (select status from public.dama_rooms where id=old_room)<>'finished' then
    raise exception 'Pré-condição: partida anterior não terminou.';
  end if;

  -- B entra noutra sala antes de A pedir revanche.
  s:=public.jl_dama_create_room(tb,10,120,'white','host',false);
  other_room:=(s->'room'->>'id')::uuid;
  code:=s->'room'->>'code';
  perform public.jl_dama_join_room(tc,code);

  begin
    perform public.jl_dama_rematch(ta,old_room,10,120,'white','host',false);
  exception
    when others then
      if position('outra partida de Dama ativa' in sqlerrm)>0 then
        failed_as_expected:=true;
      else
        raise;
      end if;
  end;

  if not failed_as_expected then
    raise exception 'Revanche deveria falhar quando o adversário já está ativo noutra sala.';
  end if;

  if exists(
    select 1
    from public.dama_room_players rp
    join public.dama_rooms r on r.id=rp.room_id
    where rp.player_id=pa and rp.status<>'left'
      and r.status in ('waiting','negotiating','funding','ready','playing')
  ) then
    raise exception 'Falha de atomicidade: uma sala ativa foi criada para A após rejeição da revanche.';
  end if;

  if (select status from public.dama_rooms where id=other_room) not in ('waiting','negotiating') then
    raise exception 'A sala ativa de B foi alterada indevidamente.';
  end if;
end
$$;
rollback;

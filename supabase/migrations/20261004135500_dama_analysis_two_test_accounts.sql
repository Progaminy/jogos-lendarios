-- Dama Lendária — motor de análise reservado a exatamente duas contas de teste.
-- A análise só fica disponível quando as duas contas autorizadas jogam entre si.

create table if not exists public.dama_analysis_testers (
  slot smallint primary key,
  player_id uuid not null unique references public.players(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint dama_analysis_testers_slot_check check (slot in (1,2))
);

alter table public.dama_analysis_testers enable row level security;
revoke all on table public.dama_analysis_testers from public, anon, authenticated;
grant select, insert, update, delete on table public.dama_analysis_testers to service_role;

create or replace function public.jl_admin_dama_analysis_testers(p_token text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.jl_admin_ok(p_token) then
    raise exception 'Sessão administrativa inválida.';
  end if;

  return jsonb_build_object(
    'slots', coalesce((
      select jsonb_agg(jsonb_build_object(
        'slot', s.slot,
        'player_id', t.player_id,
        'name', p.name,
        'phone', p.phone
      ) order by s.slot)
      from (values (1),(2)) as s(slot)
      left join public.dama_analysis_testers t on t.slot=s.slot
      left join public.players p on p.id=t.player_id
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.jl_admin_dama_analysis_set(
  p_token text,
  p_slot smallint,
  p_player_ref text
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_player uuid;
  v_ref text:=trim(coalesce(p_player_ref,''));
  v_digits text;
begin
  if not public.jl_admin_ok(p_token) then
    raise exception 'Sessão administrativa inválida.';
  end if;
  if p_slot not in (1,2) then
    raise exception 'Slot inválido. Use 1 ou 2.';
  end if;
  if v_ref='' then
    raise exception 'Informe o telefone ou UUID do jogador.';
  end if;

  if v_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
    select id into v_player from public.players where id=v_ref::uuid;
  else
    v_digits:=regexp_replace(v_ref,'[^0-9]','','g');
    select id into v_player
    from public.players
    where regexp_replace(coalesce(phone,''),'[^0-9]','','g')=v_digits
    order by created_at desc
    limit 1;
  end if;

  if v_player is null then
    raise exception 'Jogador não encontrado.';
  end if;

  if exists(
    select 1 from public.dama_analysis_testers
    where player_id=v_player and slot<>p_slot
  ) then
    raise exception 'Esta conta já ocupa o outro slot de análise.';
  end if;

  insert into public.dama_analysis_testers(slot,player_id,updated_at)
  values(p_slot,v_player,now())
  on conflict(slot) do update
  set player_id=excluded.player_id,updated_at=now();

  insert into public.audit_log(action,details)
  values('dama.analysis_tester_set',jsonb_build_object(
    'slot',p_slot,'playerId',v_player
  ));

  return public.jl_admin_dama_analysis_testers(p_token);
end;
$$;

create or replace function public.jl_admin_dama_analysis_clear(
  p_token text,
  p_slot smallint
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_player uuid;
begin
  if not public.jl_admin_ok(p_token) then
    raise exception 'Sessão administrativa inválida.';
  end if;
  if p_slot not in (1,2) then
    raise exception 'Slot inválido. Use 1 ou 2.';
  end if;

  delete from public.dama_analysis_testers
  where slot=p_slot
  returning player_id into v_player;

  insert into public.audit_log(action,details)
  values('dama.analysis_tester_cleared',jsonb_build_object(
    'slot',p_slot,'playerId',v_player
  ));

  return public.jl_admin_dama_analysis_testers(p_token);
end;
$$;

create or replace function public.jl_dama_analysis_access(p_token text,p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  v_members integer:=0;
  v_testers integer:=0;
  v_self boolean:=false;
begin
  if me is null or not public.jl_dama_is_member(p_room,me) then
    return jsonb_build_object('enabled',false,'reason','NOT_MEMBER');
  end if;

  select exists(
    select 1 from public.dama_analysis_testers where player_id=me
  ) into v_self;

  select count(*) into v_members
  from public.dama_room_players
  where room_id=p_room and status<>'left';

  select count(*) into v_testers
  from public.dama_room_players rp
  join public.dama_analysis_testers t on t.player_id=rp.player_id
  where rp.room_id=p_room and rp.status<>'left';

  return jsonb_build_object(
    'enabled', v_self and v_members=2 and v_testers=2,
    'self_authorized',v_self,
    'pair_ready',v_members=2 and v_testers=2,
    'reason',case
      when not v_self then 'ACCOUNT_NOT_AUTHORIZED'
      when v_members<>2 or v_testers<>2 then 'TEST_PAIR_REQUIRED'
      else 'OK'
    end
  );
end;
$$;

-- Snapshot reservado ao serviço. Mantido para auditoria/futuros robôs da casa.
create or replace function public.jl_dama_analysis_snapshot(p_token text,p_room uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.dama_rooms%rowtype;
  v_access jsonb;
  v_legal jsonb:='[]'::jsonb;
begin
  if me is null or not public.jl_dama_is_member(p_room,me) then
    return jsonb_build_object('allowed',false,'reason','NOT_MEMBER');
  end if;

  v_access:=public.jl_dama_analysis_access(p_token,p_room);
  if not coalesce((v_access->>'enabled')::boolean,false) then
    return jsonb_build_object('allowed',false,'reason',v_access->>'reason');
  end if;

  select * into r from public.dama_rooms where id=p_room;
  if r.id is null or r.status not in ('ready','playing') then
    return jsonb_build_object('allowed',false,'reason','GAME_NOT_ACTIVE');
  end if;
  if r.current_player_id<>me then
    return jsonb_build_object('allowed',false,'reason','NOT_YOUR_TURN');
  end if;

  v_legal:=public.jl_dama_legal_moves_data(p_room,me);
  if jsonb_array_length(v_legal)=0 then
    return jsonb_build_object('allowed',false,'reason','NO_LEGAL_MOVES');
  end if;

  return jsonb_build_object(
    'allowed',true,
    'room',jsonb_build_object(
      'id',r.id,
      'status',r.status,
      'board_version',r.board_version,
      'move_seq',r.move_seq,
      'current_player_id',r.current_player_id,
      'quiet_king_moves',r.quiet_king_moves,
      'regulation_key',r.regulation_key,
      'regulation_moves',r.regulation_moves,
      'regulation_limit',r.regulation_limit
    ),
    'me',(
      select jsonb_build_object('player_id',rp.player_id,'color',rp.color)
      from public.dama_room_players rp
      where rp.room_id=p_room and rp.player_id=me and rp.status<>'left'
      limit 1
    ),
    'opponent',(
      select jsonb_build_object('player_id',rp.player_id,'color',rp.color)
      from public.dama_room_players rp
      where rp.room_id=p_room and rp.player_id<>me and rp.status<>'left'
      limit 1
    ),
    'pieces',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',d.id,
        'player_id',d.player_id,
        'row',d.row_no,
        'col',d.col_no,
        'is_king',d.is_king
      ) order by d.player_id,d.piece_no)
      from public.dama_pieces d
      where d.room_id=p_room and d.alive
    ),'[]'::jsonb),
    'legal_moves',v_legal
  );
end;
$$;

revoke all on function public.jl_admin_dama_analysis_testers(text) from public,anon,authenticated;
revoke all on function public.jl_admin_dama_analysis_set(text,smallint,text) from public,anon,authenticated;
revoke all on function public.jl_admin_dama_analysis_clear(text,smallint) from public,anon,authenticated;
revoke all on function public.jl_dama_analysis_access(text,uuid) from public,anon,authenticated;
revoke all on function public.jl_dama_analysis_snapshot(text,uuid) from public,anon,authenticated;

grant execute on function public.jl_admin_dama_analysis_testers(text) to anon,authenticated;
grant execute on function public.jl_admin_dama_analysis_set(text,smallint,text) to anon,authenticated;
grant execute on function public.jl_admin_dama_analysis_clear(text,smallint) to anon,authenticated;
grant execute on function public.jl_dama_analysis_access(text,uuid) to anon,authenticated;
grant execute on function public.jl_dama_analysis_snapshot(text,uuid) to service_role;
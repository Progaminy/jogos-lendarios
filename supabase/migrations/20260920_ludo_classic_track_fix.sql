-- Ludo clássico: corrige a entrada na passarela final e remove a casa extra do percurso.
-- Novo percurso por peça: 0..50 pista externa, 51..55 passarela final, 56 chegada.

update public.ludo_tokens
set steps = steps - 1,
    updated_at = now()
where steps between 52 and 57;

alter table public.ludo_tokens drop constraint if exists ludo_tokens_steps_check;
alter table public.ludo_tokens
  add constraint ludo_tokens_steps_check check (steps between -1 and 56);

create or replace function public.jl_ludo_global_cell(p_color text, p_steps integer)
returns integer language sql immutable as $$
  select case
    when p_steps between 0 and 50
      then (public.jl_ludo_color_start(p_color)+p_steps)%52
    else null
  end;
$$;

create or replace function public.jl_ludo_legal_moves_data(p_room uuid,p_player uuid,p_dice integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r public.ludo_rooms%rowtype;
  rp public.ludo_room_players%rowtype;
  t record;
  ns int;
  cell int;
  exitok bool;
  caps jsonb;
  arr jsonb:='[]'::jsonb;
  blocked bool;
  i int;
  icell int;
begin
  select * into r from public.ludo_rooms where id=p_room;
  select * into rp from public.ludo_room_players where room_id=p_room and player_id=p_player;
  if r.id is null or rp.player_id is null then return '[]'::jsonb; end if;

  exitok := case r.rules->>'base_exit_rule'
    when 'one_or_six' then p_dice in (1,6)
    else p_dice=6
  end;

  for t in
    select * from public.ludo_tokens
    where room_id=p_room and player_id=p_player
    order by token_no
  loop
    blocked:=false;
    caps:='[]'::jsonb;
    cell:=null;

    if t.steps=-1 then
      if not exitok then continue; end if;
      ns:=0;
    else
      ns:=t.steps+p_dice;
      if (r.rules->>'exact_finish')::boolean and ns>56 then continue; end if;
      if ns>56 then ns:=56; end if;
      if t.steps=56 then continue; end if;
    end if;

    if ns<=50 then
      cell:=public.jl_ludo_global_cell(rp.color,ns);

      if (r.rules->>'blockades')::boolean then
        if t.steps>=0 then
          for i in t.steps+1..ns loop
            if i>50 then exit; end if;
            icell:=public.jl_ludo_global_cell(rp.color,i);
            if exists(
              select 1
              from (
                select ot.player_id,count(*) c
                from public.ludo_tokens ot
                join public.ludo_room_players op
                  on op.room_id=ot.room_id and op.player_id=ot.player_id
                where ot.room_id=p_room
                  and ot.steps between 0 and 50
                  and public.jl_ludo_global_cell(op.color,ot.steps)=icell
                  and ot.player_id<>p_player
                  and op.status in ('active','reentry','finished')
                group by ot.player_id
                having count(*)>=2
              ) z
            ) then blocked:=true; exit; end if;
          end loop;
        else
          if exists(
            select 1
            from (
              select ot.player_id,count(*) c
              from public.ludo_tokens ot
              join public.ludo_room_players op
                on op.room_id=ot.room_id and op.player_id=ot.player_id
              where ot.room_id=p_room
                and ot.steps between 0 and 50
                and public.jl_ludo_global_cell(op.color,ot.steps)=cell
                and ot.player_id<>p_player
                and op.status in ('active','reentry','finished')
              group by ot.player_id
              having count(*)>=2
            ) z
          ) then blocked:=true; end if;
        end if;
      end if;

      if blocked then continue; end if;

      if not ((r.rules->>'safe_cells')::boolean and public.jl_ludo_is_safe_cell(cell)) then
        select coalesce(
          jsonb_agg(jsonb_build_object('player_id',ot.player_id,'token_no',ot.token_no)),
          '[]'::jsonb
        )
        into caps
        from public.ludo_tokens ot
        join public.ludo_room_players op
          on op.room_id=ot.room_id and op.player_id=ot.player_id
        where ot.room_id=p_room
          and ot.player_id<>p_player
          and ot.steps between 0 and 50
          and public.jl_ludo_global_cell(op.color,ot.steps)=cell
          and op.status in ('active','reentry','finished')
          and (
            r.mode='solo'
            or op.team is distinct from rp.team
            or (r.rules->>'partner_capture')::boolean
          );
      end if;
    end if;

    arr:=arr||jsonb_build_array(jsonb_build_object(
      'token_no',t.token_no,
      'from_steps',t.steps,
      'to_steps',ns,
      'cell',cell,
      'captures',caps,
      'is_capture',jsonb_array_length(caps)>0,
      'finishes',ns=56
    ));
  end loop;

  return arr;
end;
$$;

create or replace function public.jl_ludo_check_finish(p_room uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  r public.ludo_rooms%rowtype;
  p uuid;
  tm int;
  active_players int;
  active_teams int;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.status<>'playing' then return false; end if;

  update public.ludo_room_players rp
  set status='finished'
  where rp.room_id=p_room
    and rp.status='active'
    and 4=(
      select count(*)
      from public.ludo_tokens t
      where t.room_id=p_room
        and t.player_id=rp.player_id
        and t.steps=56
    );

  if r.mode='solo' then
    select player_id into p
    from public.ludo_room_players
    where room_id=p_room and status='finished'
    order by seat limit 1;

    if p is not null then
      perform public.jl_ludo_finish_room(p_room,p,null);
      return true;
    end if;

    select count(*) into active_players
    from public.ludo_room_players
    where room_id=p_room and status in ('active','reentry');

    if active_players=1 then
      select player_id into p
      from public.ludo_room_players
      where room_id=p_room and status in ('active','reentry')
      limit 1;
      perform public.jl_ludo_finish_room(p_room,p,null);
      return true;
    end if;
  else
    select team into tm
    from public.ludo_room_players
    where room_id=p_room
    group by team
    having bool_and(status='finished') and count(*)=2
    limit 1;

    if tm is not null then
      perform public.jl_ludo_finish_room(p_room,null,tm);
      return true;
    end if;

    select count(distinct team) into active_teams
    from public.ludo_room_players
    where room_id=p_room and status in ('active','reentry','finished');

    if active_teams=1 then
      select team into tm
      from public.ludo_room_players
      where room_id=p_room and status in ('active','reentry','finished')
      limit 1;
      perform public.jl_ludo_finish_room(p_room,null,tm);
      return true;
    end if;
  end if;

  return false;
end;
$$;

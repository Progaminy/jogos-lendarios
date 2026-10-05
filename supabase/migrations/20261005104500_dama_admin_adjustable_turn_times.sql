create table if not exists public.dama_time_settings (
  id smallint primary key default 1 check (id = 1),
  option_one_seconds integer not null default 120 check (option_one_seconds between 10 and 3600),
  option_two_seconds integer not null default 180 check (option_two_seconds between 10 and 3600),
  updated_at timestamptz not null default now(),
  constraint dama_time_settings_distinct check (option_one_seconds <> option_two_seconds)
);

alter table public.dama_time_settings enable row level security;
revoke all on table public.dama_time_settings from public, anon, authenticated;

insert into public.dama_time_settings(id, option_one_seconds, option_two_seconds)
values (1, 120, 180)
on conflict (id) do nothing;

alter table public.dama_rooms drop constraint if exists dama_rooms_turn_check;
alter table public.dama_rooms add constraint dama_rooms_turn_check check (turn_seconds between 10 and 3600);

create or replace function public.jl_dama_turn_seconds_allowed(p_turn_seconds integer)
returns boolean
language sql
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.dama_time_settings s
    where s.id = 1
      and p_turn_seconds in (s.option_one_seconds, s.option_two_seconds)
  );
$$;
revoke execute on function public.jl_dama_turn_seconds_allowed(integer) from public, anon, authenticated;

create or replace function public.jl_dama_time_options(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_player uuid;
  s public.dama_time_settings%rowtype;
begin
  v_player := public.jl_player_id(p_token);
  select * into s from public.dama_time_settings where id = 1;
  return jsonb_build_object(
    'option_one_seconds', s.option_one_seconds,
    'option_two_seconds', s.option_two_seconds,
    'updated_at', s.updated_at
  );
end;
$$;
revoke execute on function public.jl_dama_time_options(text) from public;
grant execute on function public.jl_dama_time_options(text) to anon, authenticated;

create or replace function public.jl_admin_dama_time_settings(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.dama_time_settings%rowtype;
begin
  perform public.jl_require_admin(p_token);
  select * into s from public.dama_time_settings where id = 1;
  return jsonb_build_object(
    'option_one_seconds', s.option_one_seconds,
    'option_two_seconds', s.option_two_seconds,
    'updated_at', s.updated_at
  );
end;
$$;
revoke execute on function public.jl_admin_dama_time_settings(text) from public;
grant execute on function public.jl_admin_dama_time_settings(text) to anon, authenticated;

create or replace function public.jl_admin_update_dama_time_settings(
  p_token text,
  p_option_one_seconds integer,
  p_option_two_seconds integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.jl_require_admin(p_token);
  if p_option_one_seconds is null or p_option_two_seconds is null then
    raise exception 'Informe os dois tempos da Dama.';
  end if;
  if p_option_one_seconds not between 10 and 3600 or p_option_two_seconds not between 10 and 3600 then
    raise exception 'Cada tempo deve ficar entre 10 e 3600 segundos.';
  end if;
  if p_option_one_seconds = p_option_two_seconds then
    raise exception 'Os dois tempos da Dama devem ser diferentes.';
  end if;

  insert into public.dama_time_settings(id, option_one_seconds, option_two_seconds, updated_at)
  values (1, p_option_one_seconds, p_option_two_seconds, now())
  on conflict (id) do update
  set option_one_seconds = excluded.option_one_seconds,
      option_two_seconds = excluded.option_two_seconds,
      updated_at = now();

  insert into public.audit_log(action, details)
  values ('dama.turn_times_updated', jsonb_build_object(
    'optionOneSeconds', p_option_one_seconds,
    'optionTwoSeconds', p_option_two_seconds
  ));

  return public.jl_admin_dama_time_settings(p_token);
end;
$$;
revoke execute on function public.jl_admin_update_dama_time_settings(text, integer, integer) from public;
grant execute on function public.jl_admin_update_dama_time_settings(text, integer, integer) to anon, authenticated;

create or replace function public.jl_dama_create_room(
  p_token text,
  p_bet_amount numeric,
  p_turn_seconds integer default 120,
  p_host_color text default 'white'::text,
  p_first_player text default 'host'::text,
  p_is_public boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := public.jl_player_id(p_token);
  r public.dama_rooms%rowtype;
  color text := lower(trim(coalesce(p_host_color,'white')));
  firstp text := lower(trim(coalesce(p_first_player,'host')));
begin
  if p_bet_amount is null or p_bet_amount < 10 or p_bet_amount <> trunc(p_bet_amount) then
    raise exception 'A aposta deve ser um valor inteiro de pelo menos 10 MZN.';
  end if;
  if not public.jl_dama_turn_seconds_allowed(p_turn_seconds) then
    raise exception 'Tempo de jogada não permitido. Atualize a Dama e escolha um dos tempos disponíveis.';
  end if;
  if color not in ('white','red') then raise exception 'Cor inválida.'; end if;
  if firstp not in ('host','guest') then raise exception 'Quem começa é inválido.'; end if;
  if exists(
    select 1
    from public.dama_room_players rp
    join public.dama_rooms rr on rr.id = rp.room_id
    where rp.player_id = me and rp.status <> 'left'
      and rr.status in ('waiting','negotiating','funding','ready','playing')
  ) then
    raise exception 'Você já participa de uma partida de Dama ativa.';
  end if;

  insert into public.dama_rooms(
    code,host_id,bet_amount,turn_seconds,host_color,first_player_choice,is_public,status
  ) values(
    public.jl_dama_room_code(),me,p_bet_amount,p_turn_seconds,color,firstp,coalesce(p_is_public,false),'waiting'
  ) returning * into r;

  insert into public.dama_room_players(
    room_id,player_id,seat,color,settings_accepted
  ) values(r.id,me,1,color,true);

  perform public.jl_dama_event(
    r.id,me,'room_created',
    jsonb_build_object(
      'bet_amount',p_bet_amount,'turn_seconds',p_turn_seconds,
      'host_color',color,'first_player',firstp,'public',p_is_public
    )
  );

  return public.jl_dama_room_state(p_token,r.id);
end;
$$;

create or replace function public.jl_dama_update_settings(
  p_token text,
  p_room uuid,
  p_bet_amount numeric,
  p_turn_seconds integer,
  p_host_color text,
  p_first_player text,
  p_is_public boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := public.jl_player_id(p_token);
  r public.dama_rooms%rowtype;
  v_color text := lower(trim(coalesce(p_host_color,'')));
  v_first text := lower(trim(coalesce(p_first_player,'')));
begin
  select * into r from public.dama_rooms where id = p_room for update;
  if r.id is null or r.host_id <> me then raise exception 'Apenas o criador pode alterar a partida.'; end if;
  if r.status not in ('waiting','negotiating') then raise exception 'As definições já estão bloqueadas.'; end if;
  if p_bet_amount is null or p_bet_amount < 10 or p_bet_amount <> trunc(p_bet_amount) then
    raise exception 'A aposta deve ser um valor inteiro de pelo menos 10 MZN.';
  end if;
  if not public.jl_dama_turn_seconds_allowed(p_turn_seconds) then
    raise exception 'Tempo de jogada não permitido. Atualize a Dama e escolha um dos tempos disponíveis.';
  end if;
  if v_color not in ('white','red') then raise exception 'Cor inválida.'; end if;
  if v_first not in ('host','guest') then raise exception 'Quem começa é inválido.'; end if;

  update public.dama_rooms
  set bet_amount = p_bet_amount,
      turn_seconds = p_turn_seconds,
      host_color = v_color,
      first_player_choice = v_first,
      is_public = coalesce(p_is_public,false),
      status = case when guest_id is null then 'waiting' else 'negotiating' end,
      updated_at = now()
  where id = p_room;

  update public.dama_room_players rp
  set color = case
        when rp.seat = 1 then v_color
        else case v_color when 'white' then 'red' else 'white' end
      end,
      settings_accepted = (rp.seat = 1)
  where rp.room_id = p_room and rp.status <> 'left';

  perform public.jl_dama_event(
    p_room,me,'settings_changed',
    jsonb_build_object(
      'bet_amount',p_bet_amount,'turn_seconds',p_turn_seconds,
      'host_color',v_color,'first_player',v_first
    )
  );

  return public.jl_dama_room_state(p_token,p_room);
end;
$$;

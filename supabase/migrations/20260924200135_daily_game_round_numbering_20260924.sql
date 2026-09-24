alter table public.game_rounds
  rename column round_no to global_round_no;

alter table public.game_rounds
  rename constraint game_rounds_round_no_key to game_rounds_global_round_no_key;

alter table public.game_rounds
  add column round_day date,
  add column round_no integer;

with ranked as (
  select
    id,
    (draw_at at time zone 'Africa/Maputo')::date as round_day,
    row_number() over (
      partition by game_type, (draw_at at time zone 'Africa/Maputo')::date
      order by draw_at, opened_at, id
    )::integer as daily_no
  from public.game_rounds
)
update public.game_rounds g
set round_day=r.round_day,
    round_no=r.daily_no
from ranked r
where r.id=g.id;

alter table public.game_rounds
  alter column round_day set not null,
  alter column round_no set not null;

create unique index game_rounds_game_day_round_key
  on public.game_rounds(game_type,round_day,round_no);

create or replace function public.jl_assign_daily_round_no()
returns trigger
language plpgsql
set search_path=public
as $$
begin
  new.round_day := (new.draw_at at time zone 'Africa/Maputo')::date;

  if new.round_no is null then
    perform pg_advisory_xact_lock(
      hashtextextended(
        'jl_daily_round:'||new.game_type||':'||new.round_day::text,
        0
      )
    );

    select coalesce(max(g.round_no),0)+1
    into new.round_no
    from public.game_rounds g
    where g.game_type=new.game_type
      and g.round_day=new.round_day;
  end if;

  return new;
end;
$$;

drop trigger if exists jl_game_round_daily_no on public.game_rounds;

create trigger jl_game_round_daily_no
before insert on public.game_rounds
for each row
execute function public.jl_assign_daily_round_no();

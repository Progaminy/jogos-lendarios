
create or replace function public.jl_post_initial_player_balance()
returns trigger
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
begin
  if round(coalesce(new.balance,0),2)<>0 then
    insert into public.transactions(
      player_id,
      kind,
      amount,
      status,
      note
    )
    values(
      new.id,
      'adjustment',
      round(new.balance,2),
      'completed',
      'Saldo inicial · lançamento automático no ledger'
    );
  end if;

  return new;
end
$$;

drop trigger if exists jl_players_post_initial_balance
on public.players;

create trigger jl_players_post_initial_balance
after insert on public.players
for each row
execute function public.jl_post_initial_player_balance();

revoke all on function public.jl_post_initial_player_balance()
from public,anon,authenticated;

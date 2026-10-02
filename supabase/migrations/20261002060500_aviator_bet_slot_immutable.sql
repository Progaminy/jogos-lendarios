-- Aviator: o slot do painel faz parte dos termos imutáveis da aposta.
create or replace function public.jl_aviator_reject_bet_terms_mutation()
returns trigger
language plpgsql
set search_path=pg_catalog,public
as $$
begin
  if new.round_id is distinct from old.round_id
     or new.player_id is distinct from old.player_id
     or new.bet_slot is distinct from old.bet_slot
     or new.stake is distinct from old.stake
     or new.request_key is distinct from old.request_key
     or new.auto_cashout_multiplier is distinct from old.auto_cashout_multiplier
     or new.created_at is distinct from old.created_at then
    raise exception 'Termos da aposta Aviator ja confirmada sao imutaveis.';
  end if;

  return new;
end
$$;

revoke all on function public.jl_aviator_reject_bet_terms_mutation()
from public,anon,authenticated;
grant execute on function public.jl_aviator_reject_bet_terms_mutation()
to service_role;

-- Aviator: uma aposta por jogador/rodada e concorrencia escalavel.
-- Apostas usam lock compartilhado de manutencao e FOR SHARE na rodada,
-- permitindo jogadores diferentes em paralelo sem correr com fecho/manutencao.

create unique index if not exists jl_aviator_bets_player_round_uidx
  on public.jl_aviator_bets(round_id,player_id);

create or replace function public.jl_aviator_place_bet(
  p_token text,
  p_amount numeric,
  p_request_key text
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_player_id uuid:=public.jl_player_id(p_token);
  v_player public.players;
  v_round public.jl_aviator_rounds;
  v_bet public.jl_aviator_bets;
  v_existing public.jl_aviator_bets;
  v_enabled boolean;
begin
  if p_request_key is null
     or length(trim(p_request_key))<8
     or length(p_request_key)>100 then
    raise exception 'Chave da aposta invalida.';
  end if;

  -- Retry identico fica serializado apenas por jogador/chave.
  perform pg_advisory_xact_lock(
    hashtext('jl_aviator_bet_'||v_player_id::text||'_'||trim(p_request_key))
  );

  -- Apostas podem coexistir entre si; manutencao/engine usam o lock exclusivo.
  perform pg_advisory_xact_lock_shared(hashtext('jl_aviator_maintenance'));

  select *
    into v_bet
  from public.jl_aviator_bets
  where player_id=v_player_id
    and request_key=p_request_key;

  if v_bet.id is not null then
    return jsonb_build_object(
      'ok',true,
      'already_processed',true,
      'bet_id',v_bet.id,
      'round_id',v_bet.round_id,
      'stake',v_bet.stake
    );
  end if;

  select enabled
    into v_enabled
  from public.jl_aviator_settings
  where id=true;

  if coalesce(v_enabled,true)=false then
    raise exception 'Aviator em manutencao. Volte em breve.';
  end if;

  if p_amount is null or p_amount<1 or p_amount>1000000 then
    raise exception 'Valor de aposta invalido.';
  end if;

  select *
    into v_round
  from public.jl_aviator_rounds
  where status='OPEN'
    and (betting_closes_at is null or betting_closes_at>clock_timestamp())
  order by id desc
  limit 1
  for share;

  if v_round.id is null then
    raise exception 'Nao ha rodada Aviator aberta.';
  end if;

  -- Saldo e segunda aba do mesmo jogador ficam serializados apenas por jogador.
  select *
    into v_player
  from public.players
  where id=v_player_id
  for update;

  if v_player.blocked then
    raise exception 'Jogador bloqueado.';
  end if;

  select *
    into v_existing
  from public.jl_aviator_bets
  where round_id=v_round.id
    and player_id=v_player_id
  limit 1;

  if v_existing.id is not null then
    raise exception 'Ja existe uma aposta nesta rodada.';
  end if;

  if v_player.balance<p_amount then
    raise exception 'Saldo insuficiente.';
  end if;

  update public.players
     set balance=round(balance-p_amount,2),
         updated_at=now()
   where id=v_player_id;

  insert into public.jl_aviator_bets(
    round_id,
    player_id,
    stake,
    request_key
  )
  values(
    v_round.id,
    v_player_id,
    round(p_amount,2),
    p_request_key
  )
  returning * into v_bet;

  insert into public.transactions(
    player_id,
    kind,
    amount,
    status,
    note
  )
  values(
    v_player_id,
    'aviator_bet',
    -round(p_amount,2),
    'completed',
    'Aposta Aviator rodada '||v_round.id
  );

  insert into public.audit_log(action,details)
  values(
    'aviator.bet_placed',
    jsonb_build_object(
      'roundId',v_round.id,
      'betId',v_bet.id,
      'playerId',v_player_id,
      'stake',v_bet.stake
    )
  );

  return jsonb_build_object(
    'ok',true,
    'already_processed',false,
    'bet_id',v_bet.id,
    'round_id',v_round.id,
    'stake',v_bet.stake,
    'balance',v_player.balance-round(p_amount,2)
  );
end
$$;

revoke all on function public.jl_aviator_place_bet(text,numeric,text) from public;
grant execute on function public.jl_aviator_place_bet(text,numeric,text)
to anon,authenticated,service_role;

revoke all on function public.jl_aviator_place_bet(text,numeric)
from public,anon,authenticated;
grant execute on function public.jl_aviator_place_bet(text,numeric)
to service_role;

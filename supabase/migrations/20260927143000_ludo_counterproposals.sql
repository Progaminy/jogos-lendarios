-- Ludo counterproposals: any room member may propose revised rules before funding,
-- and any member may counterpropose the per-player stake during funding.

create or replace function public.jl_ludo_update_rules(
  p_token text,
  p_room uuid,
  p_rules jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  nr jsonb;
begin
  select * into r
  from public.ludo_rooms
  where id=p_room
  for update;

  if r.id is null or not public.jl_ludo_is_member(p_room,me) then
    raise exception 'Sala indisponível.';
  end if;

  if r.status not in ('waiting','negotiating') then
    raise exception 'As regras já estão bloqueadas para esta partida.';
  end if;

  nr := public.jl_ludo_rules(p_rules,r.bet_amount);

  if r.player_count=2 then
    nr:=jsonb_set(nr,'{capture_penalty}','"lose_turn"'::jsonb,true);
  end if;

  update public.ludo_rooms
  set rules=nr,
      rules_version=rules_version+1,
      status='negotiating',
      action_deadline=null,
      negotiation_grace_used=false,
      updated_at=now()
  where id=p_room
  returning * into r;

  update public.ludo_room_players
  set accepted_rules_version=null
  where room_id=p_room and status<>'left';

  update public.ludo_room_players
  set accepted_rules_version=r.rules_version
  where room_id=p_room and player_id=me and status<>'left';

  perform public.jl_ludo_event(
    p_room,
    me,
    'rules_changed',
    jsonb_build_object(
      'version',r.rules_version,
      'rules',nr,
      'proposed_by',me
    )
  );

  return public.jl_ludo_room_state(p_token,p_room);
end;
$$;

revoke all on function public.jl_ludo_update_rules(text,uuid,jsonb)
from public, anon, authenticated;
grant execute on function public.jl_ludo_update_rules(text,uuid,jsonb)
to anon, authenticated;

create or replace function public.jl_ludo_propose_bet(
  p_token text,
  p_room uuid,
  p_bet_amount numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid:=public.jl_player_id(p_token);
  r public.ludo_rooms%rowtype;
  had_paid boolean:=false;
  current_reentry numeric:=10;
  stake_secs integer:=60;
begin
  select * into r
  from public.ludo_rooms
  where id=p_room
  for update;

  if r.id is null or not public.jl_ludo_is_member(p_room,me) then
    raise exception 'Sala indisponível.';
  end if;

  if r.status<>'funding' then
    raise exception 'O valor só pode ser negociado antes do início da partida.';
  end if;

  if p_bet_amount is null
     or p_bet_amount < 10
     or p_bet_amount <> trunc(p_bet_amount) then
    raise exception 'O valor deve ser inteiro e no mínimo 10 MZN.';
  end if;

  if p_bet_amount=r.bet_amount then
    return public.jl_ludo_room_state(p_token,p_room);
  end if;

  current_reentry:=coalesce(nullif(r.rules->>'reentry_amount','')::numeric,10);
  if current_reentry>p_bet_amount then
    raise exception 'O valor proposto não pode ficar abaixo do valor de reentrada atual (% MZN).', current_reentry;
  end if;

  select exists(
    select 1
    from public.ludo_room_players
    where room_id=p_room
      and status<>'left'
      and stake_paid
  ) into had_paid;

  if had_paid then
    perform public.jl_ludo_refund_room(
      p_room,
      'Reembolso: novo valor proposto antes do início do Ludo'
    );
  else
    update public.ludo_room_players
    set stake_paid=false,
        stake_amount=0
    where room_id=p_room and status<>'left';

    update public.ludo_rooms
    set pot=0
    where id=p_room;
  end if;

  stake_secs:=greatest(
    30,
    least(coalesce(nullif(r.rules->>'stake_seconds','')::integer,60),300)
  );

  update public.ludo_rooms
  set bet_amount=p_bet_amount,
      status='funding',
      action_deadline=now()+make_interval(secs=>stake_secs),
      updated_at=now()
  where id=p_room;

  perform public.jl_ludo_event(
    p_room,
    me,
    'bet_proposed',
    jsonb_build_object(
      'old_amount',r.bet_amount,
      'amount',p_bet_amount,
      'proposed_by',me,
      'refunded_previous_acceptances',had_paid
    )
  );

  return public.jl_ludo_room_state(p_token,p_room);
end;
$$;

revoke all on function public.jl_ludo_propose_bet(text,uuid,numeric)
from public, anon, authenticated;
grant execute on function public.jl_ludo_propose_bet(text,uuid,numeric)
to anon, authenticated;

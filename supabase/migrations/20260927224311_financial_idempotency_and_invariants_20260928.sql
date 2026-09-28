-- Ponto 9 — invariantes financeiras e idempotência.
-- Preserva os fluxos existentes, acrescentando proteção contra retries duplicados,
-- saldo negativo, payouts repetidos e concorrência em reembolsos do Ludo.

create table if not exists public.financial_idempotency (
  subject_type text not null check (subject_type in ('player','admin')),
  subject_id uuid not null,
  operation text not null,
  request_key text not null,
  request_hash text not null,
  response jsonb,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  primary key (subject_type,subject_id,operation,request_key)
);

alter table public.financial_idempotency enable row level security;
revoke all privileges on table public.financial_idempotency from public, anon, authenticated;
grant select,insert,update,delete on table public.financial_idempotency to service_role;

create index if not exists financial_idempotency_created_idx
  on public.financial_idempotency(created_at desc);

do $$
begin
  if not exists(select 1 from pg_constraint where conname='players_balance_nonnegative_ck' and conrelid='public.players'::regclass) then
    alter table public.players add constraint players_balance_nonnegative_ck check (balance>=0);
  end if;
  if not exists(select 1 from pg_constraint where conname='transactions_amount_nonzero_ck' and conrelid='public.transactions'::regclass) then
    alter table public.transactions add constraint transactions_amount_nonzero_ck check (amount<>0);
  end if;
  if not exists(select 1 from pg_constraint where conname='bets_amount_breakdown_ck' and conrelid='public.bets'::regclass) then
    alter table public.bets add constraint bets_amount_breakdown_ck
      check (amount>0 and cash_amount>=0 and bonus_amount>=0 and round(cash_amount+bonus_amount,2)=round(amount,2) and payout>=0);
  end if;
  if not exists(select 1 from pg_constraint where conname='pair_bets_amount_breakdown_ck' and conrelid='public.pair_bets'::regclass) then
    alter table public.pair_bets add constraint pair_bets_amount_breakdown_ck
      check (amount>0 and cash_amount>=0 and bonus_amount>=0 and round(cash_amount+bonus_amount,2)=round(amount,2) and payout>=0);
  end if;
  if not exists(select 1 from pg_constraint where conname='ludo_room_players_stake_nonnegative_ck' and conrelid='public.ludo_room_players'::regclass) then
    alter table public.ludo_room_players add constraint ludo_room_players_stake_nonnegative_ck check (stake_amount>=0);
  end if;
  if not exists(select 1 from pg_constraint where conname='ludo_rooms_pot_nonnegative_ck' and conrelid='public.ludo_rooms'::regclass) then
    alter table public.ludo_rooms add constraint ludo_rooms_pot_nonnegative_ck check (pot>=0);
  end if;
  if not exists(select 1 from pg_constraint where conname='ludo_payouts_consistent_ck' and conrelid='public.ludo_payouts'::regclass) then
    alter table public.ludo_payouts add constraint ludo_payouts_consistent_ck
      check (gross_amount>=0 and commission>=0 and net_amount>=0 and round(gross_amount,2)=round(commission+net_amount,2));
  end if;
end
$$;

create unique index if not exists transactions_reference_once_idx
on public.transactions(kind,reference_id,player_id)
where reference_id is not null
  and kind in ('deposit','withdrawal','withdrawal_refund','bet','payout','ludo_payout');

create or replace function public.jl_financial_idempotency_claim(
  p_subject_type text,
  p_subject_id uuid,
  p_operation text,
  p_request_key text,
  p_request_hash text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_inserted boolean:=false;
  v_hash text;
  v_response jsonb;
begin
  if p_subject_type not in ('player','admin') then
    raise exception 'Tipo de operação financeira inválido.';
  end if;
  if p_subject_id is null then
    raise exception 'Identidade financeira inválida.';
  end if;
  if char_length(coalesce(p_request_key,''))<16 or char_length(p_request_key)>120 then
    raise exception 'Chave de idempotência inválida.';
  end if;

  insert into public.financial_idempotency(
    subject_type,subject_id,operation,request_key,request_hash
  ) values(
    p_subject_type,p_subject_id,p_operation,p_request_key,p_request_hash
  )
  on conflict do nothing
  returning true into v_inserted;

  if coalesce(v_inserted,false) then
    return jsonb_build_object('claimed',true);
  end if;

  select request_hash,response
  into v_hash,v_response
  from public.financial_idempotency
  where subject_type=p_subject_type
    and subject_id=p_subject_id
    and operation=p_operation
    and request_key=p_request_key;

  if v_hash is distinct from p_request_hash then
    raise exception 'A mesma chave de operação não pode ser reutilizada com dados diferentes.';
  end if;

  if v_response is null then
    raise exception 'Operação financeira ainda em processamento. Tente novamente.';
  end if;

  return jsonb_build_object('claimed',false,'response',v_response);
end;
$function$;

revoke all on function public.jl_financial_idempotency_claim(text,uuid,text,text,text)
from public,anon,authenticated;

create or replace function public.jl_financial_idempotency_complete(
  p_subject_type text,
  p_subject_id uuid,
  p_operation text,
  p_request_key text,
  p_response jsonb
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  update public.financial_idempotency
  set response=p_response,completed_at=now()
  where subject_type=p_subject_type
    and subject_id=p_subject_id
    and operation=p_operation
    and request_key=p_request_key;
  if not found then raise exception 'Registo de idempotência financeira não encontrado.'; end if;
end;
$function$;

revoke all on function public.jl_financial_idempotency_complete(text,uuid,text,text,jsonb)
from public,anon,authenticated;

create or replace function public.jl_request_deposit_idempotent(
  p_token text,p_amount numeric,p_note text,p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_player uuid:=public.jl_player_id(p_token);
  v_hash text; v_claim jsonb; v_response jsonb;
begin
  v_hash:=encode(extensions.digest(jsonb_build_object(
    'amount',round(coalesce(p_amount,0),2),
    'note',left(trim(coalesce(p_note,'')),160)
  )::text,'sha256'),'hex');

  v_claim:=public.jl_financial_idempotency_claim(
    'player',v_player,'deposit_request',p_idempotency_key,v_hash
  );
  if not (v_claim->>'claimed')::boolean then return v_claim->'response'; end if;

  v_response:=public.jl_request_deposit(p_token,p_amount,p_note);
  perform public.jl_financial_idempotency_complete(
    'player',v_player,'deposit_request',p_idempotency_key,v_response
  );
  return v_response;
end;
$function$;

create or replace function public.jl_request_withdrawal_idempotent(
  p_token text,p_amount numeric,p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_player uuid:=public.jl_player_id(p_token);
  v_hash text; v_claim jsonb; v_response jsonb;
begin
  v_hash:=encode(extensions.digest(
    jsonb_build_object('amount',round(coalesce(p_amount,0),2))::text,'sha256'
  ),'hex');

  v_claim:=public.jl_financial_idempotency_claim(
    'player',v_player,'withdrawal_request',p_idempotency_key,v_hash
  );
  if not (v_claim->>'claimed')::boolean then return v_claim->'response'; end if;

  v_response:=public.jl_request_withdrawal(p_token,p_amount);
  perform public.jl_financial_idempotency_complete(
    'player',v_player,'withdrawal_request',p_idempotency_key,v_response
  );
  return v_response;
end;
$function$;

create or replace function public.jl_place_bet_idempotent(
  p_token text,p_selected_number integer,p_amount numeric,p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_player uuid:=public.jl_player_id(p_token);
  v_hash text; v_claim jsonb; v_response jsonb;
begin
  v_hash:=encode(extensions.digest(jsonb_build_object(
    'number',p_selected_number,'amount',coalesce(p_amount,0)
  )::text,'sha256'),'hex');

  v_claim:=public.jl_financial_idempotency_claim(
    'player',v_player,'number_bet',p_idempotency_key,v_hash
  );
  if not (v_claim->>'claimed')::boolean then return v_claim->'response'; end if;

  v_response:=public.jl_place_bet(p_token,p_selected_number,p_amount);
  perform public.jl_financial_idempotency_complete(
    'player',v_player,'number_bet',p_idempotency_key,v_response
  );
  return v_response;
end;
$function$;

create or replace function public.jl_place_pair_bet_idempotent(
  p_token text,p_number_a integer,p_number_b integer,p_amount numeric,p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_player uuid:=public.jl_player_id(p_token);
  v_a integer:=least(p_number_a,p_number_b);
  v_b integer:=greatest(p_number_a,p_number_b);
  v_hash text; v_claim jsonb; v_response jsonb;
begin
  v_hash:=encode(extensions.digest(jsonb_build_object(
    'number_a',v_a,'number_b',v_b,'amount',coalesce(p_amount,0)
  )::text,'sha256'),'hex');

  v_claim:=public.jl_financial_idempotency_claim(
    'player',v_player,'pair_bet',p_idempotency_key,v_hash
  );
  if not (v_claim->>'claimed')::boolean then return v_claim->'response'; end if;

  v_response:=public.jl_place_pair_bet(p_token,p_number_a,p_number_b,p_amount);
  perform public.jl_financial_idempotency_complete(
    'player',v_player,'pair_bet',p_idempotency_key,v_response
  );
  return v_response;
end;
$function$;

create or replace function public.jl_admin_adjust_balance_idempotent(
  p_token text,p_player_id uuid,p_delta numeric,p_note text,p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_admin uuid:=public.jl_admin_account_id(p_token);
  v_hash text; v_claim jsonb; v_response jsonb;
begin
  if v_admin is null then raise exception 'Sessão administrativa inválida ou expirada.'; end if;

  v_hash:=encode(extensions.digest(jsonb_build_object(
    'player_id',p_player_id,
    'delta',round(coalesce(p_delta,0),2),
    'note',left(trim(coalesce(p_note,'')),160)
  )::text,'sha256'),'hex');

  v_claim:=public.jl_financial_idempotency_claim(
    'admin',v_admin,'balance_adjustment',p_idempotency_key,v_hash
  );
  if not (v_claim->>'claimed')::boolean then return v_claim->'response'; end if;

  v_response:=public.jl_admin_adjust_balance(p_token,p_player_id,p_delta,p_note);
  perform public.jl_financial_idempotency_complete(
    'admin',v_admin,'balance_adjustment',p_idempotency_key,v_response
  );
  return v_response;
end;
$function$;

revoke all on function public.jl_request_deposit_idempotent(text,numeric,text,text) from public,anon,authenticated;
grant execute on function public.jl_request_deposit_idempotent(text,numeric,text,text) to anon,authenticated,service_role;
revoke all on function public.jl_request_withdrawal_idempotent(text,numeric,text) from public,anon,authenticated;
grant execute on function public.jl_request_withdrawal_idempotent(text,numeric,text) to anon,authenticated,service_role;
revoke all on function public.jl_place_bet_idempotent(text,integer,numeric,text) from public,anon,authenticated;
grant execute on function public.jl_place_bet_idempotent(text,integer,numeric,text) to anon,authenticated,service_role;
revoke all on function public.jl_place_pair_bet_idempotent(text,integer,integer,numeric,text) from public,anon,authenticated;
grant execute on function public.jl_place_pair_bet_idempotent(text,integer,integer,numeric,text) to anon,authenticated,service_role;
revoke all on function public.jl_admin_adjust_balance_idempotent(text,uuid,numeric,text,text) from public,anon,authenticated;
grant execute on function public.jl_admin_adjust_balance_idempotent(text,uuid,numeric,text,text) to anon,authenticated,service_role;

create or replace function public.jl_ludo_refund_room(
  p_room uuid,p_note text default 'Reembolso Ludo'
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  x record;
  restored numeric;
begin
  perform 1 from public.ludo_rooms where id=p_room for update;

  for x in
    select *
    from public.ludo_room_players
    where room_id=p_room and stake_paid
    order by seat
    for update
  loop
    update public.players
    set balance=balance+x.stake_amount,updated_at=now()
    where id=x.player_id;

    restored:=public.jl_reverse_cash_wager(x.player_id,'ludo_stake',p_room);

    insert into public.transactions(player_id,kind,amount,status,reference_id,note)
    values(
      x.player_id,'ludo_refund',x.stake_amount,'completed',p_room,
      p_note||' · '||restored||' MZN voltaram a ficar bloqueados até serem jogados'
    );
  end loop;

  update public.ludo_room_players
  set stake_paid=false,stake_amount=0
  where room_id=p_room and stake_paid;

  update public.ludo_rooms set pot=0,updated_at=now() where id=p_room;
end;
$function$;

create or replace function public.jl_ludo_finish_room(
  p_room uuid,p_winner uuid,p_team integer
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r public.ludo_rooms%rowtype;
  gross numeric;
  comm numeric;
  net numeric;
  x record;
  total_comm numeric:=0;
  v_payout_id uuid;
begin
  select * into r from public.ludo_rooms where id=p_room for update;
  if r.status='finished' then return; end if;

  if r.mode='solo' then
    if p_winner is null then raise exception 'Vencedor inválido.'; end if;
    gross:=round(r.pot,2);
    comm:=least(gross,greatest(1,ceil(gross*0.01)));
    net:=gross-comm;
    v_payout_id:=null;

    insert into public.ludo_payouts(room_id,player_id,gross_amount,commission,net_amount)
    values(p_room,p_winner,gross,comm,net)
    on conflict(room_id,player_id) do nothing
    returning id into v_payout_id;

    if v_payout_id is not null then
      update public.players set balance=balance+net,updated_at=now() where id=p_winner;
      insert into public.transactions(player_id,kind,amount,status,reference_id,note)
      values(p_winner,'ludo_payout',net,'completed',p_room,'Prémio Ludo líquido; comissão '||comm||' MZN');
    else
      select commission into comm from public.ludo_payouts where room_id=p_room and player_id=p_winner;
    end if;

    total_comm:=coalesce(comm,0);
    update public.ludo_room_players
    set status=case when player_id=p_winner then 'finished' else status end
    where room_id=p_room;
  else
    if p_team not in (1,2) then raise exception 'Equipa vencedora inválida.'; end if;
    gross:=round(r.pot/2,2);

    for x in
      select player_id from public.ludo_room_players
      where room_id=p_room and team=p_team order by seat
    loop
      comm:=least(gross,greatest(1,ceil(gross*0.01)));
      net:=gross-comm;
      v_payout_id:=null;

      insert into public.ludo_payouts(room_id,player_id,gross_amount,commission,net_amount)
      values(p_room,x.player_id,gross,comm,net)
      on conflict(room_id,player_id) do nothing
      returning id into v_payout_id;

      if v_payout_id is not null then
        update public.players set balance=balance+net,updated_at=now() where id=x.player_id;
        insert into public.transactions(player_id,kind,amount,status,reference_id,note)
        values(x.player_id,'ludo_payout',net,'completed',p_room,'Prémio Ludo parceiros líquido; comissão individual '||comm||' MZN');
      else
        select commission into comm from public.ludo_payouts where room_id=p_room and player_id=x.player_id;
      end if;

      total_comm:=total_comm+coalesce(comm,0);
    end loop;
  end if;

  update public.ludo_rooms
  set status='finished',winner_player_id=p_winner,winner_team=p_team,
      commission_total=total_comm,turn_phase=null,dice_result=null,
      action_deadline=null,finished_at=now(),updated_at=now()
  where id=p_room;

  perform public.jl_ludo_event(
    p_room,p_winner,'game_finished',
    jsonb_build_object(
      'winner_player_id',p_winner,'winner_team',p_team,
      'pot',r.pot,'commission_total',total_comm
    )
  );
end;
$function$;

-- Aviator: cancelamento administrativo explícito, com motivo obrigatório e reembolso.
-- Permitido somente antes de o crash ser efetivado: OPEN, LOCKED ou FLYING.

alter table public.jl_aviator_rounds
  add column if not exists admin_cancelled_at timestamptz,
  add column if not exists admin_cancel_reason text,
  add column if not exists admin_cancelled_by uuid,
  add column if not exists admin_cancel_refunded_bets integer,
  add column if not exists admin_cancel_refunded_total numeric(18,2);

do $$
begin
  if not exists(
    select 1
    from pg_constraint
    where conrelid='public.jl_aviator_rounds'::regclass
      and conname='jl_aviator_rounds_admin_cancelled_by_fkey'
  ) then
    alter table public.jl_aviator_rounds
      add constraint jl_aviator_rounds_admin_cancelled_by_fkey
      foreign key(admin_cancelled_by)
      references public.admin_accounts(id)
      on delete restrict;
  end if;
end
$$;

alter table public.jl_aviator_rounds
  drop constraint if exists jl_aviator_rounds_admin_cancel_fields_check;

alter table public.jl_aviator_rounds
  add constraint jl_aviator_rounds_admin_cancel_fields_check
  check(
    admin_cancelled_at is null
    or (
      status='CANCELLED'
      and admin_cancelled_by is not null
      and length(btrim(admin_cancel_reason)) between 5 and 240
      and admin_cancel_refunded_bets is not null
      and admin_cancel_refunded_bets>=0
      and admin_cancel_refunded_total is not null
      and admin_cancel_refunded_total>=0
    )
  );

create index if not exists jl_aviator_rounds_admin_cancelled_by_idx
on public.jl_aviator_rounds(admin_cancelled_by)
where admin_cancelled_by is not null;

create or replace function public.jl_aviator_admin_cancel_round(
  p_token text,
  p_round_id bigint,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  v_admin uuid;
  v_round public.jl_aviator_rounds;
  v_bet public.jl_aviator_bets;
  v_tx uuid;
  v_reason text:=btrim(coalesce(p_reason,''));
  v_now timestamptz:=clock_timestamp();
  v_refunded_bets integer:=0;
  v_refunded_total numeric:=0;
  v_cashouts integer:=0;
  v_cashout_paid numeric:=0;
begin
  v_admin:=public.jl_admin_account_id(p_token);

  if v_admin is null then
    raise exception 'Sessão administrativa inválida ou expirada.';
  end if;

  if p_round_id is null then
    raise exception 'Rodada inválida.';
  end if;

  if length(v_reason)<5 then
    raise exception 'Informe um motivo com pelo menos 5 caracteres.';
  end if;

  if length(v_reason)>240 then
    raise exception 'O motivo pode ter no máximo 240 caracteres.';
  end if;

  -- Mesma ordem do motor/manutenção para impedir corrida com lock, crash ou cash-out.
  perform pg_advisory_xact_lock(hashtext('jl_aviator_engine_tick'));
  perform pg_advisory_xact_lock(hashtext('jl_aviator_maintenance'));
  perform pg_advisory_xact_lock(hashtext('jl_aviator_round_'||p_round_id::text));

  select *
    into v_round
  from public.jl_aviator_rounds
  where id=p_round_id
  for update;

  if v_round.id is null then
    raise exception 'Rodada não encontrada.';
  end if;

  if v_round.status='CANCELLED'
     and v_round.admin_cancelled_at is not null then
    return jsonb_build_object(
      'ok',true,
      'already_cancelled',true,
      'round_id',v_round.id,
      'status',v_round.status,
      'reason',v_round.admin_cancel_reason,
      'refunded_bets',coalesce(v_round.admin_cancel_refunded_bets,0),
      'refunded_total',coalesce(v_round.admin_cancel_refunded_total,0)
    );
  end if;

  if v_round.status not in ('OPEN','LOCKED','FLYING') then
    raise exception
      'Esta rodada já encerrou e não pode ser cancelada administrativamente.';
  end if;

  select
    count(*) filter(where status='CASHED_OUT'),
    coalesce(sum(payout) filter(where status='CASHED_OUT'),0)
    into v_cashouts,v_cashout_paid
  from public.jl_aviator_bets
  where round_id=v_round.id;

  for v_bet in
    select *
    from public.jl_aviator_bets
    where round_id=v_round.id
      and status='ACTIVE'
    order by id
    for update
  loop
    insert into public.transactions(
      player_id,
      kind,
      amount,
      status,
      note
    )
    values(
      v_bet.player_id,
      'aviator_refund',
      v_bet.stake,
      'completed',
      left(
        'Reembolso Aviator · cancelamento administrativo · rodada '||
        v_round.id||' · aposta '||v_bet.id||' · '||v_reason,
        500
      )
    )
    returning id into v_tx;

    update public.players
       set balance=round(balance+v_bet.stake,2),
           updated_at=v_now
     where id=v_bet.player_id;

    update public.jl_aviator_bets
       set status='REFUNDED',
           payout=v_bet.stake,
           refunded_at=v_now,
           refund_transaction_id=v_tx
     where id=v_bet.id
       and status='ACTIVE';

    if found then
      v_refunded_bets:=v_refunded_bets+1;
      v_refunded_total:=v_refunded_total+v_bet.stake;
    end if;
  end loop;

  update public.jl_aviator_rounds
     set status='CANCELLED',
         settled_at=coalesce(settled_at,v_now),
         next_round_at=null,
         admin_cancelled_at=v_now,
         admin_cancel_reason=v_reason,
         admin_cancelled_by=v_admin,
         admin_cancel_refunded_bets=v_refunded_bets,
         admin_cancel_refunded_total=round(v_refunded_total,2)
   where id=v_round.id
  returning * into v_round;

  insert into public.audit_log(
    action,
    details,
    actor_admin_id,
    actor_session_id,
    actor_name,
    actor_role,
    target_type,
    target_id,
    before_state,
    after_state
  )
  values(
    'aviator.round_admin_cancelled',
    jsonb_build_object(
      'roundId',v_round.id,
      'reason',v_reason,
      'refundedBets',v_refunded_bets,
      'refundedTotal',round(v_refunded_total,2),
      'cashoutsKept',v_cashouts,
      'cashoutPaidKept',v_cashout_paid,
      'cancelledAt',v_now
    ),
    v_admin,
    nullif(current_setting('jl.admin_session_id',true),'')::uuid,
    nullif(current_setting('jl.admin_name',true),''),
    nullif(current_setting('jl.admin_role',true),''),
    'aviator_round',
    v_round.id::text,
    jsonb_build_object(
      'status',case
        when v_round.started_at is null and v_round.locked_at is null then 'OPEN'
        when v_round.started_at is null then 'LOCKED'
        else 'FLYING'
      end
    ),
    jsonb_build_object(
      'status','CANCELLED',
      'reason',v_reason,
      'refundedBets',v_refunded_bets,
      'refundedTotal',round(v_refunded_total,2)
    )
  );

  return jsonb_build_object(
    'ok',true,
    'already_cancelled',false,
    'round_id',v_round.id,
    'status','CANCELLED',
    'reason',v_reason,
    'refunded_bets',v_refunded_bets,
    'refunded_total',round(v_refunded_total,2),
    'cashouts_kept',v_cashouts,
    'cashout_paid_kept',v_cashout_paid
  );
end
$$;

revoke all on function public.jl_aviator_admin_cancel_round(text,bigint,text)
from public;
grant execute on function public.jl_aviator_admin_cancel_round(text,bigint,text)
to anon,authenticated;

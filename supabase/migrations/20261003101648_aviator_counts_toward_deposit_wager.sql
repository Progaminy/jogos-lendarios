-- Aviator must count toward the same "deposit must be wagered before withdrawal" rule
-- already used by Número, Dupla and Ludo. Refunded Aviator bets restore the lock.

alter table public.deposit_wager_usages
  drop constraint if exists deposit_wager_usages_source_type_check;

alter table public.deposit_wager_usages
  add constraint deposit_wager_usages_source_type_check
  check (
    source_type in (
      'number_bet',
      'pair_bet',
      'ludo_stake',
      'ludo_reentry',
      'aviator_bet'
    )
  );

create or replace function public.jl_apply_cash_wager(
  p_player_id uuid,
  p_amount numeric,
  p_source_type text,
  p_reference_id uuid
)
returns numeric
language plpgsql
security definer
set search_path=public
as $$
declare
  r public.deposit_wager_requirements%rowtype;
  need numeric:=greatest(0,coalesce(p_amount,0));
  take numeric;
  cleared numeric:=0;
begin
  if p_source_type not in (
    'number_bet',
    'pair_bet',
    'ludo_stake',
    'ludo_reentry',
    'aviator_bet'
  ) then
    raise exception 'Origem de jogo inválida.';
  end if;

  if need<=0 then
    return 0;
  end if;

  for r in
    select *
    from public.deposit_wager_requirements
    where player_id=p_player_id
      and status='active'
      and remaining_amount>0
    order by created_at,id
    for update
  loop
    exit when need<=0;

    take:=least(need,r.remaining_amount);

    update public.deposit_wager_requirements
    set remaining_amount=remaining_amount-take,
        status=case
          when remaining_amount-take<=0 then 'cleared'
          else 'active'
        end,
        updated_at=now()
    where id=r.id;

    insert into public.deposit_wager_usages(
      requirement_id,
      player_id,
      source_type,
      reference_id,
      amount
    )
    values(
      r.id,
      p_player_id,
      p_source_type,
      p_reference_id,
      take
    );

    cleared:=cleared+take;
    need:=need-take;
  end loop;

  return cleared;
end;
$$;

revoke all on function public.jl_apply_cash_wager(uuid,numeric,text,uuid)
  from public,anon,authenticated;

create or replace function public.jl_aviator_wager_reference(p_bet_id bigint)
returns uuid
language sql
immutable
strict
set search_path=pg_catalog
as $$
  select md5('jl:aviator_bet:'||p_bet_id::text)::uuid;
$$;

revoke all on function public.jl_aviator_wager_reference(bigint)
  from public,anon,authenticated;

create or replace function public.jl_track_aviator_deposit_wager()
returns trigger
language plpgsql
security definer
set search_path=pg_catalog,public
as $$
declare
  v_ref uuid;
begin
  v_ref:=public.jl_aviator_wager_reference(new.id);

  if tg_op='INSERT' then
    perform public.jl_apply_cash_wager(
      new.player_id,
      new.stake,
      'aviator_bet',
      v_ref
    );
    return new;
  end if;

  if tg_op='UPDATE'
     and old.status is distinct from new.status
     and new.status='REFUNDED' then
    perform public.jl_reverse_cash_wager(
      new.player_id,
      'aviator_bet',
      v_ref
    );
  end if;

  return new;
end;
$$;

revoke all on function public.jl_track_aviator_deposit_wager()
  from public,anon,authenticated;

drop trigger if exists jl_aviator_deposit_wager_track
  on public.jl_aviator_bets;

create trigger jl_aviator_deposit_wager_track
after insert or update of status
on public.jl_aviator_bets
for each row
execute function public.jl_track_aviator_deposit_wager();

-- Reconcile already-placed, non-refunded Aviator bets without allowing
-- an old bet to clear a deposit created after that bet.
do $$
declare
  b record;
  r record;
  v_ref uuid;
  need numeric;
  take numeric;
  v_rows integer:=0;
  v_cleared numeric:=0;
begin
  for b in
    select id,player_id,stake,created_at,status
    from public.jl_aviator_bets
    where status<>'REFUNDED'
    order by created_at,id
  loop
    v_ref:=public.jl_aviator_wager_reference(b.id);

    if exists(
      select 1
      from public.deposit_wager_usages u
      where u.player_id=b.player_id
        and u.source_type='aviator_bet'
        and u.reference_id=v_ref
    ) then
      continue;
    end if;

    need:=greatest(0,coalesce(b.stake,0));

    for r in
      select *
      from public.deposit_wager_requirements
      where player_id=b.player_id
        and created_at<=b.created_at
        and status='active'
        and remaining_amount>0
      order by created_at,id
      for update
    loop
      exit when need<=0;

      take:=least(need,r.remaining_amount);

      update public.deposit_wager_requirements
      set remaining_amount=remaining_amount-take,
          status=case
            when remaining_amount-take<=0 then 'cleared'
            else 'active'
          end,
          updated_at=now()
      where id=r.id;

      insert into public.deposit_wager_usages(
        requirement_id,
        player_id,
        source_type,
        reference_id,
        amount
      )
      values(
        r.id,
        b.player_id,
        'aviator_bet',
        v_ref,
        take
      );

      v_rows:=v_rows+1;
      v_cleared:=v_cleared+take;
      need:=need-take;
    end loop;
  end loop;

  insert into public.audit_log(action,details)
  values(
    'deposit_wager.aviator_backfill',
    jsonb_build_object(
      'usageRows',v_rows,
      'clearedAmount',round(v_cleared,2),
      'appliedAt',clock_timestamp()
    )
  );
end;
$$;

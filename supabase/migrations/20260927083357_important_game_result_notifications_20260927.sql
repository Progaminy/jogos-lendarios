create or replace function public.jl_notify_number_win()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if coalesce(new.won,false)
     and coalesce(new.payout,0)>0
     and (tg_op='INSERT' or not coalesce(old.won,false) or old.payout is distinct from new.payout) then
    perform public.jl_notification_create(
      new.player_id,
      'win',
      'Parabéns! Você ganhou',
      'Você ganhou '||new.payout||' MZN no Número Lendário.',
      './index.html#playerArea',
      'number-win:'||new.id::text
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_jl_notify_number_win on public.bets;
create trigger trg_jl_notify_number_win
after insert or update of won,payout on public.bets
for each row execute function public.jl_notify_number_win();

create or replace function public.jl_notify_pair_win()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if coalesce(new.won,false)
     and coalesce(new.payout,0)>0
     and (tg_op='INSERT' or not coalesce(old.won,false) or old.payout is distinct from new.payout) then
    perform public.jl_notification_create(
      new.player_id,
      'win',
      'Parabéns! Você ganhou',
      'Você ganhou '||new.payout||' MZN na Dupla Lendária.',
      './index.html#playerArea',
      'pair-win:'||new.id::text
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_jl_notify_pair_win on public.pair_bets;
create trigger trg_jl_notify_pair_win
after insert or update of won,payout on public.pair_bets
for each row execute function public.jl_notify_pair_win();

create or replace function public.jl_notify_ludo_payout()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  room_code text;
begin
  if coalesce(new.net_amount,0)<=0 then return new; end if;
  select code into room_code from public.ludo_rooms where id=new.room_id;

  perform public.jl_notification_create(
    new.player_id,
    'win',
    'Vitória no Ludo',
    'Você ganhou '||new.net_amount||' MZN na partida '||coalesce(room_code,new.room_id::text)||'.',
    './ludo.html#resultPanel',
    'ludo-payout:'||new.id::text
  );
  return new;
end;
$$;

drop trigger if exists trg_jl_notify_ludo_payout on public.ludo_payouts;
create trigger trg_jl_notify_ludo_payout
after insert on public.ludo_payouts
for each row execute function public.jl_notify_ludo_payout();

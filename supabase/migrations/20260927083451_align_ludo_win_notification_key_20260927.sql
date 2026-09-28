
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
    'ludo-win:'||new.room_id::text||':'||new.player_id::text||':'||new.net_amount::text
  );
  return new;
end;
$$;

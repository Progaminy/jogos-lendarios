create or replace function public.jl_notify_ludo_payout()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  room_code text;
  net_key text;
begin
  if coalesce(new.net_amount,0)<=0 then return new; end if;
  select code into room_code from public.ludo_rooms where id=new.room_id;
  net_key:=regexp_replace(
    regexp_replace(new.net_amount::text,'(\.[0-9]*?)0+$','\1'),
    '\.$',''
  );

  perform public.jl_notification_create(
    new.player_id,
    'win',
    'Vitória no Ludo',
    'Você ganhou '||new.net_amount||' MZN na partida '||coalesce(room_code,new.room_id::text)||'.',
    './ludo.html#resultPanel',
    'ludo-win:'||new.room_id::text||':'||new.player_id::text||':'||net_key
  );
  return new;
end;
$$;

revoke all on function public.jl_notify_ludo_payout() from public, anon, authenticated;

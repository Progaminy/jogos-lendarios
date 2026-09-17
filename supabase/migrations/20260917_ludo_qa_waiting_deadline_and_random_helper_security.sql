create or replace function public.jl_ludo_create_room(
  p_token text,
  p_player_count integer,
  p_bet_amount numeric,
  p_mode text default 'solo'::text,
  p_is_public boolean default false,
  p_rules jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_player uuid := public.jl_player_id(p_token);
  v_room public.ludo_rooms%rowtype;
  v_rules jsonb;
begin
  if p_player_count not between 2 and 4 then raise exception 'Ludo aceita 2, 3 ou 4 jogadores.'; end if;
  if p_mode not in ('solo','partners') then raise exception 'Modo inválido.'; end if;
  if p_mode='partners' and p_player_count<>4 then raise exception 'Modo parceiros requer 4 jogadores.'; end if;
  if p_bet_amount is null or p_bet_amount < 10 then raise exception 'A aposta mínima é 10 MZN.'; end if;
  if exists(
    select 1
    from public.ludo_room_players rp
    join public.ludo_rooms r on r.id=rp.room_id
    where rp.player_id=v_player
      and rp.status<>'left'
      and r.status in ('waiting','negotiating','funding','playing')
  ) then raise exception 'Você já participa de uma sala de Ludo ativa.'; end if;

  perform public.jl_ludo_ensure_code(v_player);
  v_rules := public.jl_ludo_rules(p_rules,p_bet_amount);

  insert into public.ludo_rooms(
    code,host_id,player_count,mode,bet_amount,is_public,rules,status,action_deadline
  ) values(
    public.jl_ludo_room_code(),v_player,p_player_count,p_mode,round(p_bet_amount,2),p_is_public,v_rules,'waiting',null
  ) returning * into v_room;

  insert into public.ludo_room_players(
    room_id,player_id,seat,color,team,accepted_rules_version
  ) values(
    v_room.id,v_player,1,'red',case when p_mode='partners' then 1 else null end,v_room.rules_version
  );

  perform public.jl_ludo_event(
    v_room.id,v_player,'room_created',
    jsonb_build_object('code',v_room.code,'bet',v_room.bet_amount,'players',v_room.player_count,'mode',v_room.mode)
  );

  return public.jl_ludo_room_state(p_token,v_room.id);
end;
$function$;

revoke execute on function public.jl_random_index(integer) from public, anon, authenticated;

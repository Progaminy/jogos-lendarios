-- Ludo: saída da base somente com 6
-- 2026-09-23

create or replace function public.jl_ludo_rules(p_rules jsonb, p_bet numeric)
returns jsonb
language plpgsql
immutable
set search_path to 'public'
as $function$
declare
  r jsonb := public.jl_ludo_defaults() || coalesce(p_rules,'{}'::jsonb);
  n numeric;
  dc integer;
  loc text;
begin
  if (r->>'turn_seconds')::integer not between 30 and 120 then raise exception 'Tempo de jogada deve estar entre 30 e 120 segundos.'; end if;
  if (r->>'move_seconds')::integer not between 15 and 60 then raise exception 'Tempo para escolher a peça deve estar entre 15 e 60 segundos.'; end if;
  if (r->>'rules_response_seconds')::integer not between 30 and 60 then raise exception 'Tempo de resposta das regras deve estar entre 30 e 60 segundos.'; end if;
  if (r->>'stake_seconds')::integer not between 30 and 60 then raise exception 'Tempo para confirmar aposta deve estar entre 30 e 60 segundos.'; end if;
  if (r->>'reentry_seconds')::integer not between 30 and 60 then raise exception 'Tempo de reentrada deve estar entre 30 e 60 segundos.'; end if;
  if (r->>'idle_strikes_limit')::integer not between 1 and 5 then raise exception 'Limite de ausências deve estar entre 1 e 5.'; end if;
  if r->>'capture_penalty' not in ('lose_turn','eliminate','eliminate_reentry') then raise exception 'Penalização de captura obrigatória inválida.'; end if;

  n := (r->>'reentry_amount')::numeric;
  if n < 10 or n > p_bet then raise exception 'Valor de reentrada deve ficar entre 10 MZN e a aposta da sala.'; end if;

  loc := coalesce(r->>'play_location','online');
  if loc not in ('online','presential') then raise exception 'Local da partida deve ser online ou presencial.'; end if;

  dc := coalesce((r->>'dice_count')::integer,1);
  if dc not in (1,2,3,4) then raise exception 'Quantidade de dados deve ser 1, 2, 3 ou 4.'; end if;

  if dc > 1 then
    r := jsonb_set(r,'{six_extra_turn}','false'::jsonb,true);
    r := jsonb_set(r,'{capture_extra_turn}','false'::jsonb,true);
    r := jsonb_set(r,'{three_sixes_penalty}','false'::jsonb,true);
  end if;

  r := jsonb_set(r,'{base_exit_rule}','"six"'::jsonb,true);
  r := jsonb_set(r,'{blockades}','false'::jsonb,true);
  r := jsonb_set(r,'{voice_enabled}','true'::jsonb,true);

  return r;
end;
$function$;

create or replace function public.jl_ludo_legal_moves_data(p_room uuid, p_player uuid, p_dice integer)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r public.ludo_rooms%rowtype;
  rp public.ludo_room_players%rowtype;
  t record;
  ns int;
  cell int;
  caps jsonb;
  arr jsonb:='[]'::jsonb;
begin
  select * into r from public.ludo_rooms where id=p_room;
  select * into rp from public.ludo_room_players where room_id=p_room and player_id=p_player;
  if r.id is null or rp.player_id is null then return '[]'::jsonb; end if;

  for t in
    select * from public.ludo_tokens
    where room_id=p_room and player_id=p_player
    order by token_no
  loop
    caps:='[]'::jsonb;
    cell:=null;

    if t.steps=-1 then
      if p_dice<>6 then continue; end if;
      ns:=0;
    else
      ns:=t.steps+p_dice;
      if (r.rules->>'exact_finish')::boolean and ns>56 then continue; end if;
      if ns>56 then ns:=56; end if;
      if t.steps=56 then continue; end if;
    end if;

    if ns<=50 then
      cell:=public.jl_ludo_global_cell(rp.color,ns);
      if not ((r.rules->>'safe_cells')::boolean and public.jl_ludo_is_safe_cell(cell)) then
        select coalesce(jsonb_agg(jsonb_build_object('player_id',ot.player_id,'token_no',ot.token_no)),'[]'::jsonb)
        into caps
        from public.ludo_tokens ot
        join public.ludo_room_players op on op.room_id=ot.room_id and op.player_id=ot.player_id
        where ot.room_id=p_room
          and ot.player_id<>p_player
          and ot.steps between 0 and 50
          and public.jl_ludo_global_cell(op.color,ot.steps)=cell
          and op.status in ('active','reentry','finished')
          and (r.mode='solo' or op.team is distinct from rp.team or (r.rules->>'partner_capture')::boolean);
      end if;
    end if;

    arr:=arr||jsonb_build_array(jsonb_build_object(
      'token_no',t.token_no,'from_steps',t.steps,'to_steps',ns,'cell',cell,
      'captures',caps,'is_capture',jsonb_array_length(caps)>0,'finishes',ns=56
    ));
  end loop;
  return arr;
end;
$function$;

update public.ludo_rooms
set rules=jsonb_set(rules,'{base_exit_rule}','"six"'::jsonb,true),
    updated_at=now()
where status not in ('finished','cancelled')
  and coalesce(rules->>'base_exit_rule','six') <> 'six';

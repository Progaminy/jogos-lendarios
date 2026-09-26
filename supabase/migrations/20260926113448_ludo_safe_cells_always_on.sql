-- Casas seguras são uma regra fixa do Ludo Lendário.
-- Nenhuma sala pode desativá-las, inclusive por chamada direta à RPC.

update public.ludo_rooms
set rules = jsonb_set(coalesce(rules,'{}'::jsonb), '{safe_cells}', 'true'::jsonb, true),
    updated_at = now()
where coalesce((rules->>'safe_cells')::boolean, false) is distinct from true;

alter table public.ludo_rooms
  drop constraint if exists ludo_rooms_safe_cells_always_on;

alter table public.ludo_rooms
  add constraint ludo_rooms_safe_cells_always_on
  check (coalesce((rules->>'safe_cells')::boolean, false) = true);

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

  -- Regras fixas do Ludo.
  r := jsonb_set(r,'{base_exit_rule}','"six"'::jsonb,true);
  r := jsonb_set(r,'{safe_cells}','true'::jsonb,true);
  r := jsonb_set(r,'{blockades}','false'::jsonb,true);
  r := jsonb_set(r,'{voice_enabled}','true'::jsonb,true);

  return r;
end;
$function$;

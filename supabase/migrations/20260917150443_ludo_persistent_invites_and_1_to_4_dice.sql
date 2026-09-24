create or replace function public.jl_ludo_defaults()
returns jsonb
language sql
immutable
set search_path to 'public'
as $$
  select jsonb_build_object(
    'turn_seconds',120,
    'move_seconds',30,
    'rules_response_seconds',60,
    'stake_seconds',60,
    'reentry_seconds',60,
    'capture_required',false,
    'capture_penalty','eliminate_reentry',
    'reentry_allowed',true,
    'reentry_amount',10,
    'partner_capture',false,
    'capture_extra_turn',true,
    'six_extra_turn',true,
    'three_sixes_penalty',true,
    'safe_cells',true,
    'blockades',true,
    'exact_finish',true,
    'base_exit_rule','six',
    'idle_strikes_limit',3,
    'voice_enabled',true,
    'chat_enabled',true,
    'private_room',true,
    'play_location','online',
    'dice_count',1
  );
$$;

create or replace function public.jl_ludo_rules(p_rules jsonb, p_bet numeric)
returns jsonb
language plpgsql
immutable
set search_path to 'public'
as $$
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
  if r->>'base_exit_rule' not in ('six','one_or_six') then raise exception 'Regra de saída da base inválida.'; end if;
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

  return r;
end;
$$;

update public.ludo_invitations i
set expires_at = null
where status = 'pending';

update public.ludo_rooms
set public_challenge_expires_at = null
where is_public and status in ('waiting','negotiating');

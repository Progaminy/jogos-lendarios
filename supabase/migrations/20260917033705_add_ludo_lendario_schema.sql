-- Ludo Lendario - motor multiplayer, negociacao, apostas, temporizadores e voz WebRTC.
create table if not exists public.ludo_player_codes (
  player_id uuid primary key references public.players(id) on delete cascade,
  house_number bigint generated always as identity unique,
  created_at timestamptz not null default now()
);
create table if not exists public.ludo_rooms (
  id uuid primary key default extensions.gen_random_uuid(),
  code text not null unique,
  host_id uuid not null references public.players(id) on delete restrict,
  player_count integer not null check (player_count between 2 and 4),
  mode text not null default 'solo' check (mode in ('solo','partners')),
  bet_amount numeric(14,2) not null check (bet_amount >= 1),
  pot numeric(14,2) not null default 0 check (pot >= 0),
  is_public boolean not null default false,
  rules jsonb not null default '{}'::jsonb,
  rules_version integer not null default 1 check (rules_version >= 1),
  status text not null default 'waiting' check (status in ('waiting','negotiating','funding','playing','finished','cancelled')),
  turn_phase text check (turn_phase is null or turn_phase in ('roll','move')),
  current_player_id uuid references public.players(id) on delete restrict,
  dice_result integer check (dice_result is null or dice_result between 1 and 6),
  action_deadline timestamptz,
  winner_player_id uuid references public.players(id) on delete restrict,
  winner_team integer check (winner_team is null or winner_team in (1,2)),
  commission_total numeric(14,2) not null default 0 check (commission_total >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  check (mode <> 'partners' or player_count = 4)
);
create table if not exists public.ludo_room_players (
  room_id uuid not null references public.ludo_rooms(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete restrict,
  seat integer not null check (seat between 1 and 4),
  color text not null check (color in ('red','green','yellow','blue')),
  team integer check (team is null or team in (1,2)),
  accepted_rules_version integer,
  stake_paid boolean not null default false,
  stake_amount numeric(14,2) not null default 0 check (stake_amount >= 0),
  status text not null default 'active' check (status in ('active','reentry','eliminated','finished','left')),
  timeout_strikes integer not null default 0 check (timeout_strikes >= 0),
  consecutive_sixes integer not null default 0 check (consecutive_sixes >= 0),
  reentry_deadline timestamptz,
  joined_at timestamptz not null default now(),
  primary key (room_id, player_id), unique (room_id, seat), unique (room_id, color)
);
create table if not exists public.ludo_tokens (
  room_id uuid not null, player_id uuid not null,
  token_no integer not null check (token_no between 1 and 4),
  steps integer not null default -1 check (steps between -1 and 57),
  updated_at timestamptz not null default now(),
  primary key (room_id, player_id, token_no),
  foreign key (room_id, player_id) references public.ludo_room_players(room_id, player_id) on delete cascade
);
create table if not exists public.ludo_invitations (
  id uuid primary key default extensions.gen_random_uuid(), room_id uuid not null references public.ludo_rooms(id) on delete cascade,
  invited_by uuid not null references public.players(id) on delete restrict, target_player_id uuid not null references public.players(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','declined','expired','cancelled')),
  expires_at timestamptz not null, created_at timestamptz not null default now()
);
create table if not exists public.ludo_waiting_queue (
  player_id uuid primary key references public.players(id) on delete cascade,
  bet_amount numeric(14,2) not null check (bet_amount >= 1), player_count integer not null check (player_count between 2 and 4),
  mode text not null check (mode in ('solo','partners')), joined_at timestamptz not null default now(), expires_at timestamptz not null,
  check (mode <> 'partners' or player_count = 4)
);
create table if not exists public.ludo_events (
  id bigint generated always as identity primary key, room_id uuid not null references public.ludo_rooms(id) on delete cascade,
  player_id uuid references public.players(id) on delete set null, event_type text not null, payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create table if not exists public.ludo_chat (
  id bigint generated always as identity primary key, room_id uuid not null references public.ludo_rooms(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade, message text not null check (char_length(message) between 1 and 500),
  created_at timestamptz not null default now()
);
create table if not exists public.ludo_signals (
  id bigint generated always as identity primary key, room_id uuid not null references public.ludo_rooms(id) on delete cascade,
  from_player_id uuid not null references public.players(id) on delete cascade, to_player_id uuid not null references public.players(id) on delete cascade,
  signal_type text not null check (signal_type in ('offer','answer','ice','renegotiate')), payload jsonb not null,
  created_at timestamptz not null default now(), expires_at timestamptz not null default (now() + interval '2 minutes'),
  check (octet_length(payload::text) <= 50000)
);
create table if not exists public.ludo_payouts (
  id uuid primary key default extensions.gen_random_uuid(), room_id uuid not null references public.ludo_rooms(id) on delete restrict,
  player_id uuid not null references public.players(id) on delete restrict, gross_amount numeric(14,2) not null check (gross_amount >= 0),
  commission numeric(14,2) not null check (commission >= 0), net_amount numeric(14,2) not null check (net_amount >= 0),
  created_at timestamptz not null default now(), unique(room_id, player_id)
);
create index if not exists ludo_rooms_status_idx on public.ludo_rooms(status, created_at desc);
create index if not exists ludo_room_players_player_idx on public.ludo_room_players(player_id, status);
create index if not exists ludo_invites_target_idx on public.ludo_invitations(target_player_id, status, expires_at);
create index if not exists ludo_queue_match_idx on public.ludo_waiting_queue(player_count, mode, bet_amount, joined_at);
create index if not exists ludo_events_room_idx on public.ludo_events(room_id, id desc);
create index if not exists ludo_chat_room_idx on public.ludo_chat(room_id, id desc);
create index if not exists ludo_signals_target_idx on public.ludo_signals(to_player_id, room_id, id);
alter table public.ludo_player_codes enable row level security;
alter table public.ludo_rooms enable row level security;
alter table public.ludo_room_players enable row level security;
alter table public.ludo_tokens enable row level security;
alter table public.ludo_invitations enable row level security;
alter table public.ludo_waiting_queue enable row level security;
alter table public.ludo_events enable row level security;
alter table public.ludo_chat enable row level security;
alter table public.ludo_signals enable row level security;
alter table public.ludo_payouts enable row level security;
revoke all on public.ludo_player_codes, public.ludo_rooms, public.ludo_room_players, public.ludo_tokens, public.ludo_invitations, public.ludo_waiting_queue, public.ludo_events, public.ludo_chat, public.ludo_signals, public.ludo_payouts from anon, authenticated;
alter table public.transactions drop constraint if exists transactions_kind_check;
alter table public.transactions add constraint transactions_kind_check check (kind = any(array['deposit'::text,'withdrawal'::text,'withdrawal_refund'::text,'bet'::text,'payout'::text,'adjustment'::text,'ludo_stake'::text,'ludo_reentry'::text,'ludo_refund'::text,'ludo_payout'::text]));
create or replace function public.jl_ludo_defaults() returns jsonb language sql immutable as $$ select jsonb_build_object('turn_seconds',120,'move_seconds',30,'rules_response_seconds',60,'stake_seconds',60,'invite_seconds',60,'reentry_seconds',60,'capture_required',false,'capture_penalty','eliminate_reentry','reentry_allowed',true,'reentry_amount',10,'partner_capture',false,'capture_extra_turn',true,'six_extra_turn',true,'three_sixes_penalty',true,'safe_cells',true,'blockades',true,'exact_finish',true,'base_exit_rule','six','idle_strikes_limit',3,'voice_enabled',true,'chat_enabled',true,'private_room',true); $$;
create or replace function public.jl_ludo_rules(p_rules jsonb, p_bet numeric) returns jsonb language plpgsql immutable as $$
declare r jsonb := public.jl_ludo_defaults() || coalesce(p_rules,'{}'::jsonb); n numeric;
begin
 if (r->>'turn_seconds')::integer not between 30 and 120 then raise exception 'Tempo de jogada deve estar entre 30 e 120 segundos.'; end if;
 if (r->>'move_seconds')::integer not between 15 and 60 then raise exception 'Tempo para escolher a peça deve estar entre 15 e 60 segundos.'; end if;
 if (r->>'rules_response_seconds')::integer not between 30 and 60 then raise exception 'Tempo de resposta das regras deve estar entre 30 e 60 segundos.'; end if;
 if (r->>'stake_seconds')::integer not between 30 and 60 then raise exception 'Tempo para confirmar aposta deve estar entre 30 e 60 segundos.'; end if;
 if (r->>'invite_seconds')::integer not between 30 and 60 then raise exception 'Tempo de convite deve estar entre 30 e 60 segundos.'; end if;
 if (r->>'reentry_seconds')::integer not between 30 and 60 then raise exception 'Tempo de reentrada deve estar entre 30 e 60 segundos.'; end if;
 if (r->>'idle_strikes_limit')::integer not between 1 and 5 then raise exception 'Limite de ausências deve estar entre 1 e 5.'; end if;
 if r->>'capture_penalty' not in ('lose_turn','eliminate','eliminate_reentry') then raise exception 'Penalização de captura obrigatória inválida.'; end if;
 if r->>'base_exit_rule' not in ('six','one_or_six') then raise exception 'Regra de saída da base inválida.'; end if;
 n := (r->>'reentry_amount')::numeric; if n < 1 or n > p_bet then raise exception 'Valor de reentrada deve ficar entre 1 MZN e a aposta da sala.'; end if; return r;
end; $$;
create or replace function public.jl_ludo_ensure_code(p_player_id uuid) returns bigint language plpgsql security definer set search_path = public, extensions as $$ declare n bigint; begin insert into public.ludo_player_codes(player_id) values(p_player_id) on conflict(player_id) do nothing; select house_number into n from public.ludo_player_codes where player_id=p_player_id; return n; end; $$;
create or replace function public.jl_ludo_display_code(p_player_id uuid) returns text language plpgsql security definer set search_path = public as $$ declare n bigint; nm text; begin n := public.jl_ludo_ensure_code(p_player_id); select name into nm from public.players where id=p_player_id; return coalesce(nullif(split_part(trim(nm),' ',1),''),'Jogador') || lpad(n::text,3,'0'); end; $$;
create or replace function public.jl_ludo_room_code() returns text language plpgsql security definer set search_path = public, extensions as $$ declare c text; begin loop c := 'LUDO-' || upper(substr(encode(extensions.gen_random_bytes(4),'hex'),1,6)); exit when not exists(select 1 from public.ludo_rooms where code=c); end loop; return c; end; $$;
create or replace function public.jl_ludo_is_member(p_room uuid, p_player uuid) returns boolean language sql security definer set search_path = public as $$ select exists(select 1 from public.ludo_room_players where room_id=p_room and player_id=p_player and status <> 'left'); $$;
create or replace function public.jl_ludo_color_start(p_color text) returns integer language sql immutable as $$ select case p_color when 'red' then 0 when 'green' then 13 when 'yellow' then 26 when 'blue' then 39 else null end; $$;
create or replace function public.jl_ludo_global_cell(p_color text, p_steps integer) returns integer language sql immutable as $$ select case when p_steps between 0 and 51 then (public.jl_ludo_color_start(p_color)+p_steps)%52 else null end; $$;
create or replace function public.jl_ludo_is_safe_cell(p_cell integer) returns boolean language sql immutable as $$ select p_cell = any(array[0,8,13,21,26,34,39,47]); $$;
create or replace function public.jl_ludo_event(p_room uuid, p_player uuid, p_type text, p_payload jsonb default '{}'::jsonb) returns void language sql security definer set search_path = public as $$ insert into public.ludo_events(room_id,player_id,event_type,payload) values(p_room,p_player,p_type,coalesce(p_payload,'{}'::jsonb)); $$;

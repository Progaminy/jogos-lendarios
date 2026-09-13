create table if not exists messages (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references players(id) on delete cascade,
  sender_role text not null check (sender_role in ('player','admin')),
  body text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);

create index if not exists idx_messages_player_created
  on messages(player_id, created_at desc);

alter table messages enable row level security;

grant select, insert, update, delete on messages to service_role;

-- Sem políticas públicas: todas as leituras/escritas passam pela Edge Function,
-- que autentica o jogador ou o administrador antes de consultar esta tabela.

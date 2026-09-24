create table if not exists admin_config (
  id smallint primary key check (id = 1),
  code_hash text not null,
  updated_at timestamptz not null default now()
);

create table if not exists admin_sessions (
  id uuid primary key default gen_random_uuid(),
  token_hash text not null unique,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

alter table admin_config enable row level security;
alter table admin_sessions enable row level security;

grant select, insert, update, delete on admin_config, admin_sessions to service_role;
create index if not exists idx_admin_sessions_token on admin_sessions(token_hash);
create index if not exists idx_admin_sessions_expiry on admin_sessions(expires_at);

create table if not exists public.audit_log (
  id uuid primary key default gen_random_uuid(),
  action text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.audit_log enable row level security;

revoke all on table public.audit_log from anon, authenticated;

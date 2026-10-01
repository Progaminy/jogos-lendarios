update public.ludo_rooms
set rules = jsonb_set(coalesce(rules,'{}'::jsonb), '{blockades}', 'false'::jsonb, true),
    updated_at = now()
where coalesce((rules->>'blockades')::boolean, false) is distinct from false;

alter table public.ludo_rooms
  drop constraint if exists ludo_rooms_blockades_always_off;

alter table public.ludo_rooms
  add constraint ludo_rooms_blockades_always_off
  check (coalesce((rules->>'blockades')::boolean, false) = false);

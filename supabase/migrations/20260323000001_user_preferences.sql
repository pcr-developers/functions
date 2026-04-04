create table if not exists public.user_preferences (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  theme        text not null default 'light' check (theme in ('light', 'dark', 'system')),
  display_name text,
  updated_at   timestamptz not null default now()
);

alter table public.user_preferences enable row level security;

create policy "user_preferences_select" on public.user_preferences
  for select to authenticated
  using (user_id = auth.uid());

create policy "user_preferences_insert" on public.user_preferences
  for insert to authenticated
  with check (user_id = auth.uid());

create policy "user_preferences_update" on public.user_preferences
  for update to authenticated
  using (user_id = auth.uid());

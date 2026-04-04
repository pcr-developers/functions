-- Teams
create table if not exists public.teams (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  slug       text not null unique,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- Team members
create table if not exists public.team_members (
  id        uuid primary key default gen_random_uuid(),
  team_id   uuid not null references public.teams(id) on delete cascade,
  user_id   uuid not null references auth.users(id) on delete cascade,
  role      text not null default 'member' check (role in ('owner', 'admin', 'member')),
  joined_at timestamptz not null default now(),
  unique (team_id, user_id)
);

-- Team invites
create table if not exists public.team_invites (
  id          uuid primary key default gen_random_uuid(),
  team_id     uuid not null references public.teams(id) on delete cascade,
  email       text not null,
  role        text not null default 'member' check (role in ('admin', 'member')),
  token       text not null unique default encode(gen_random_bytes(32), 'hex'),
  invited_by  uuid references auth.users(id) on delete set null,
  expires_at  timestamptz not null default (now() + interval '7 days'),
  accepted_at timestamptz,
  created_at  timestamptz not null default now()
);


-- Helper functions (created after tables so the relation exists)

-- Returns the team_id the current user belongs to, bypassing RLS
-- to avoid infinite recursion in team_members policies.
create or replace function public.my_team_id()
returns uuid
language sql
security definer
stable
set search_path = public
as $$
  select team_id from public.team_members where user_id = auth.uid() limit 1;
$$;

-- Returns true if the current user is an owner or admin of their team
create or replace function public.i_am_owner_or_admin()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.team_members
    where user_id = auth.uid() and role in ('owner', 'admin')
  );
$$;


-- RLS

alter table public.teams enable row level security;
alter table public.team_members enable row level security;
alter table public.team_invites enable row level security;

-- teams
create policy "teams_insert" on public.teams
  for insert to authenticated
  with check (created_by = auth.uid());

create policy "teams_select" on public.teams
  for select to authenticated
  using (
    id = public.my_team_id()
    or created_by = auth.uid()
  );

create policy "teams_update" on public.teams
  for update to authenticated
  using (id = public.my_team_id() and public.i_am_owner_or_admin());

create policy "teams_delete" on public.teams
  for delete to authenticated
  using (created_by = auth.uid());

-- team_members
create policy "team_members_insert_self" on public.team_members
  for insert to authenticated
  with check (user_id = auth.uid());

create policy "team_members_insert_others" on public.team_members
  for insert to authenticated
  with check (
    team_id = public.my_team_id() and public.i_am_owner_or_admin()
  );

create policy "team_members_select" on public.team_members
  for select to authenticated
  using (team_id = public.my_team_id());

create policy "team_members_update" on public.team_members
  for update to authenticated
  using (team_id = public.my_team_id() and public.i_am_owner_or_admin());

create policy "team_members_delete" on public.team_members
  for delete to authenticated
  using (
    user_id = auth.uid()
    or (team_id = public.my_team_id() and public.i_am_owner_or_admin())
  );

-- profiles: team members can see each other
create policy "profiles_select_by_team_member" on public.profiles
  for select to authenticated
  using (
    id in (
      select user_id from public.team_members
      where team_id = public.my_team_id()
    )
  );

-- team_invites
create policy "team_invites_insert" on public.team_invites
  for insert to authenticated
  with check (
    team_id = public.my_team_id() and public.i_am_owner_or_admin()
  );

create policy "team_invites_select_admin" on public.team_invites
  for select to authenticated
  using (
    team_id = public.my_team_id() and public.i_am_owner_or_admin()
  );

create policy "team_invites_select_by_token" on public.team_invites
  for select to authenticated
  using (true);

create policy "team_invites_update" on public.team_invites
  for update to authenticated
  using (true);

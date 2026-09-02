-- ClubQ Training: database, permissions and storage. Run once in the Supabase SQL editor.
create extension if not exists pgcrypto;

-- Who may act as a coach. Email is matched to the signed-in user's email.
create table if not exists coaches (
  email text primary key,
  name text not null,
  role text not null default 'coach' check (role in ('admin','coach')),
  created_at timestamptz not null default now()
);

create table if not exists clients (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text,                          -- the address the client logs in with
  goal text default '',
  status text not null default 'active' check (status in ('active','paused','archived')),
  created_at date not null default current_date,
  targets jsonb not null default '{}'::jsonb,
  habits jsonb not null default '[]'::jsonb,
  intake jsonb,
  updated_at timestamptz not null default now()
);
create unique index if not exists clients_email_idx on clients (lower(email)) where email is not null;

-- Which coach may see which client. Admins see everyone regardless.
create table if not exists coach_clients (
  coach_email text not null references coaches(email) on delete cascade,
  client_id uuid not null references clients(id) on delete cascade,
  primary key (coach_email, client_id)
);

create table if not exists sessions (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references clients(id) on delete cascade,
  date date not null,
  title text not null default 'Session',
  focus text default '',
  status text not null default 'planned' check (status in ('planned','done')),
  items jsonb not null default '[]'::jsonb,
  rating int,
  client_note text,
  coach_comment text,
  completed_at timestamptz,
  moved_from date,
  moved_by_client boolean default false,
  updated_at timestamptz not null default now()
);
create index if not exists sessions_client_date_idx on sessions (client_id, date);

create table if not exists metrics (
  client_id uuid not null references clients(id) on delete cascade,
  date date not null,
  weight numeric,
  calories numeric,
  protein numeric,
  steps numeric,
  notes text,
  habits jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (client_id, date)
);

create table if not exists exmeta (
  slug text primary key,
  name text not null,
  video_url text
);

-- keep updated_at fresh
create or replace function set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
drop trigger if exists clients_touch on clients;  create trigger clients_touch  before update on clients  for each row execute function set_updated_at();
drop trigger if exists sessions_touch on sessions; create trigger sessions_touch before update on sessions for each row execute function set_updated_at();
drop trigger if exists metrics_touch on metrics;  create trigger metrics_touch  before update on metrics  for each row execute function set_updated_at();

-- ---------- helpers used by the rules ----------
create or replace function my_email() returns text language sql stable as $$
  select lower(coalesce(auth.jwt() ->> 'email', ''))
$$;
create or replace function is_coach() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from coaches where lower(email) = my_email())
$$;
create or replace function is_admin() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from coaches where lower(email) = my_email() and role = 'admin')
$$;
create or replace function coach_can(cid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select is_admin() or exists (select 1 from coach_clients where client_id = cid and lower(coach_email) = my_email())
$$;
create or replace function is_own_client(cid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from clients where id = cid and email is not null and lower(email) = my_email())
$$;
create or replace function my_client_id() returns uuid language sql stable security definer set search_path = public as $$
  select id from clients where email is not null and lower(email) = my_email() limit 1
$$;

-- ---------- row level security ----------
alter table coaches enable row level security;
alter table clients enable row level security;
alter table coach_clients enable row level security;
alter table sessions enable row level security;
alter table metrics enable row level security;
alter table exmeta enable row level security;

-- coaches: every coach can see the coach list (needed for assigning); only admins change it
drop policy if exists coaches_read on coaches;   create policy coaches_read   on coaches for select using (is_coach());
drop policy if exists coaches_write on coaches;  create policy coaches_write  on coaches for all using (is_admin()) with check (is_admin());

-- coach_clients: coaches see their own assignments, admins everything and manage it
drop policy if exists cc_read on coach_clients;  create policy cc_read  on coach_clients for select using (is_admin() or lower(coach_email) = my_email());
drop policy if exists cc_write on coach_clients; create policy cc_write on coach_clients for all using (is_admin()) with check (is_admin());

-- clients: a coach sees clients they are allowed; a client sees only themself
drop policy if exists clients_read on clients;   create policy clients_read   on clients for select using (coach_can(id) or is_own_client(id));
drop policy if exists clients_insert on clients; create policy clients_insert on clients for insert with check (is_coach());
drop policy if exists clients_update on clients; create policy clients_update on clients for update using (coach_can(id)) with check (coach_can(id));
drop policy if exists clients_delete on clients; create policy clients_delete on clients for delete using (is_admin());

-- sessions: coaches (allowed) full control; clients read and update their own (logging, moving, adding an exercise)
drop policy if exists sessions_read on sessions;   create policy sessions_read   on sessions for select using (coach_can(client_id) or is_own_client(client_id));
drop policy if exists sessions_insert on sessions; create policy sessions_insert on sessions for insert with check (coach_can(client_id));
drop policy if exists sessions_update on sessions; create policy sessions_update on sessions for update using (coach_can(client_id) or is_own_client(client_id)) with check (coach_can(client_id) or is_own_client(client_id));
drop policy if exists sessions_delete on sessions; create policy sessions_delete on sessions for delete using (coach_can(client_id));

-- metrics: coaches read and write for their clients; clients read and write their own
drop policy if exists metrics_rw on metrics; create policy metrics_rw on metrics for all using (coach_can(client_id) or is_own_client(client_id)) with check (coach_can(client_id) or is_own_client(client_id));

-- exercise video links: everyone signed in can read, coaches write
drop policy if exists exmeta_read on exmeta;  create policy exmeta_read  on exmeta for select using (auth.role() = 'authenticated');
drop policy if exists exmeta_write on exmeta; create policy exmeta_write on exmeta for all using (is_coach()) with check (is_coach());

-- live sync between devices
do $$ begin
  alter publication supabase_realtime add table clients;  exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table sessions; exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table metrics;  exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table exmeta;   exception when duplicate_object then null; end $$;

-- ---------- storage for progress photos and client videos ----------
insert into storage.buckets (id, name, public, file_size_limit)
values ('media', 'media', false, 104857600)
on conflict (id) do nothing;

-- files live at media/<client_id>/... ; a client reaches only their own folder, coaches reach their clients'
drop policy if exists media_read on storage.objects;
create policy media_read on storage.objects for select
  using (bucket_id = 'media' and (coach_can(((storage.foldername(name))[1])::uuid) or is_own_client(((storage.foldername(name))[1])::uuid)));
drop policy if exists media_write on storage.objects;
create policy media_write on storage.objects for insert
  with check (bucket_id = 'media' and (coach_can(((storage.foldername(name))[1])::uuid) or is_own_client(((storage.foldername(name))[1])::uuid)));
drop policy if exists media_delete on storage.objects;
create policy media_delete on storage.objects for delete
  using (bucket_id = 'media' and (coach_can(((storage.foldername(name))[1])::uuid) or is_own_client(((storage.foldername(name))[1])::uuid)));

-- ---------- the coaches ----------
insert into coaches (email, name, role) values
  ('info@clubqhealth.com', 'Harry', 'admin')
on conflict (email) do update set name = excluded.name, role = excluded.role;
-- Add Alina and Layne once their login emails are known:
-- insert into coaches (email, name, role) values ('alina@…', 'Alina', 'admin'), ('layne@…', 'Layne', 'coach');

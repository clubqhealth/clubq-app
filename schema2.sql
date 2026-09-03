-- ClubQ Training: exercise library table. Run once in the Supabase SQL editor (after schema.sql).
create table if not exists exercises (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  cats jsonb not null default '[]'::jsonb,        -- [{cat, sub}], an exercise can sit in several
  skill int not null default 1,
  equipment text[] not null default '{}',
  muscles text[] not null default '{}',
  plane text,
  at_clubq boolean not null default true,
  mode text,
  video_url text,
  notes text,
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists exercises_name_idx on exercises (lower(name));
drop trigger if exists exercises_touch on exercises; create trigger exercises_touch before update on exercises for each row execute function set_updated_at();

alter table exercises enable row level security;
drop policy if exists exercises_read on exercises;  create policy exercises_read  on exercises for select using (auth.role() = 'authenticated');
drop policy if exists exercises_write on exercises; create policy exercises_write on exercises for all using (is_admin()) with check (is_admin());

do $$ begin
  alter publication supabase_realtime add table exercises; exception when duplicate_object then null; end $$;

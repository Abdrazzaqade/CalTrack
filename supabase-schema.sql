-- ═══════════════════════════════════════════════════════════════
--  CalTrack — database schema
--  Paste the whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
-- ═══════════════════════════════════════════════════════════════

-- The old anonymous leaderboard table is replaced by the tables below.
-- Uncomment this line if you created it earlier and want it gone:
-- drop table if exists caltrack_users;


-- ── 1. Profiles ────────────────────────────────────────────────
-- One row per account. This is the ONLY table other people can read
-- from, and only for people in a challenge with you.
create table if not exists profiles (
  id            uuid primary key references auth.users on delete cascade,
  display_name  text not null default 'Friend',
  avatar        text not null default '🙂',
  streak        int  not null default 0,
  best_streak   int  not null default 0,
  badges        int  not null default 0,
  updated_at    timestamptz not null default now()
);

-- ── 2. Settings ────────────────────────────────────────────────
-- Calorie goal, macro split, step/water targets, custom foods,
-- saved meals, favourites. Private. Stored as one JSON blob so the
-- app can evolve without another migration.
create table if not exists settings (
  user_id     uuid primary key references auth.users on delete cascade,
  data        jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now()
);

-- ── 3. Days ────────────────────────────────────────────────────
-- One row per user per day. foods/acts hold the detail; the numeric
-- columns are kept alongside so the challenge can be scored without
-- anything reading the food log itself.
create table if not exists days (
  user_id     uuid not null references auth.users on delete cascade,
  date        date not null,
  foods       jsonb not null default '[]'::jsonb,
  acts        jsonb not null default '[]'::jsonb,
  steps       int   not null default 0,
  water       int   not null default 0,
  kcal_in     int   not null default 0,
  kcal_out    int   not null default 0,
  protein     numeric not null default 0,
  points      int   not null default 0,
  updated_at  timestamptz not null default now(),
  primary key (user_id, date)
);
create index if not exists days_user_date_idx on days (user_id, date desc);

-- ── 4. Weights ─────────────────────────────────────────────────
create table if not exists weights (
  user_id     uuid not null references auth.users on delete cascade,
  date        date not null,
  kg          numeric not null,
  updated_at  timestamptz not null default now(),
  primary key (user_id, date)
);

-- ── 5. Challenges ──────────────────────────────────────────────
create table if not exists challenges (
  id          uuid primary key default gen_random_uuid(),
  code        text unique not null,
  name        text not null,
  starts      date not null,
  ends        date not null,
  created_by  uuid references auth.users on delete set null,
  created_at  timestamptz not null default now()
);

create table if not exists challenge_members (
  challenge_id uuid not null references challenges on delete cascade,
  user_id      uuid not null references auth.users on delete cascade,
  joined_at    timestamptz not null default now(),
  primary key (challenge_id, user_id)
);
create index if not exists cm_user_idx on challenge_members (user_id);


-- ═══════════════════════════════════════════════════════════════
--  ROW LEVEL SECURITY
--  Without these policies every table is readable by anyone with
--  the public key. With them, you can only ever touch your own rows.
-- ═══════════════════════════════════════════════════════════════
alter table profiles          enable row level security;
alter table settings          enable row level security;
alter table days              enable row level security;
alter table weights           enable row level security;
alter table challenges        enable row level security;
alter table challenge_members enable row level security;

-- profiles: you manage your own; reading others goes through
-- challenge_board() below, never directly.
drop policy if exists "own profile read"   on profiles;
drop policy if exists "own profile write"  on profiles;
drop policy if exists "own profile update" on profiles;
create policy "own profile read"   on profiles for select using (auth.uid() = id);
create policy "own profile write"  on profiles for insert with check (auth.uid() = id);
create policy "own profile update" on profiles for update using (auth.uid() = id) with check (auth.uid() = id);

-- settings / days / weights: strictly your own, all four verbs.
do $$
declare t text;
begin
  foreach t in array array['settings','days','weights'] loop
    execute format('drop policy if exists "own rows select" on %I', t);
    execute format('drop policy if exists "own rows insert" on %I', t);
    execute format('drop policy if exists "own rows update" on %I', t);
    execute format('drop policy if exists "own rows delete" on %I', t);
    execute format('create policy "own rows select" on %I for select using (auth.uid() = user_id)', t);
    execute format('create policy "own rows insert" on %I for insert with check (auth.uid() = user_id)', t);
    execute format('create policy "own rows update" on %I for update using (auth.uid() = user_id) with check (auth.uid() = user_id)', t);
    execute format('create policy "own rows delete" on %I for delete using (auth.uid() = user_id)', t);
  end loop;
end $$;

-- challenges: any signed-in user may create one; members may read theirs.
drop policy if exists "members read challenge" on challenges;
drop policy if exists "create challenge"       on challenges;
create policy "members read challenge" on challenges for select
  using (exists (select 1 from challenge_members m
                 where m.challenge_id = challenges.id and m.user_id = auth.uid()));
create policy "create challenge" on challenges for insert
  with check (auth.uid() = created_by);

-- membership: you add and remove only yourself.
drop policy if exists "read own membership"  on challenge_members;
drop policy if exists "join challenge"       on challenge_members;
drop policy if exists "leave challenge"      on challenge_members;
create policy "read own membership" on challenge_members for select using (auth.uid() = user_id);
create policy "join challenge"      on challenge_members for insert with check (auth.uid() = user_id);
create policy "leave challenge"     on challenge_members for delete using (auth.uid() = user_id);


-- ═══════════════════════════════════════════════════════════════
--  JOINING BY CODE
--  Codes are looked up through this function rather than by reading
--  the challenges table, so a code reveals nothing until you join.
-- ═══════════════════════════════════════════════════════════════
create or replace function join_challenge(p_code text)
returns table (id uuid, code text, name text, starts date, ends date)
language plpgsql security definer set search_path = public as $$
declare ch challenges%rowtype;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into ch from challenges c where c.code = upper(trim(p_code));
  if not found then raise exception 'No challenge with that code'; end if;
  insert into challenge_members (challenge_id, user_id)
    values (ch.id, auth.uid()) on conflict do nothing;
  return query select ch.id, ch.code, ch.name, ch.starts, ch.ends;
end $$;
revoke all on function join_challenge(text) from public;
grant execute on function join_challenge(text) to authenticated;


-- ═══════════════════════════════════════════════════════════════
--  THE LEADERBOARD
--  Returns scores only — never food, weight, macros or calorie goals.
--  Callers must already be a member of the challenge they ask about.
--  p_from / p_to narrow it to a single month.
-- ═══════════════════════════════════════════════════════════════
create or replace function challenge_board(p_code text, p_from date default null, p_to date default null)
returns table (
  user_id      uuid,
  display_name text,
  avatar       text,
  points       bigint,
  days_logged  bigint,
  streak       int,
  best_streak  int,
  badges       int,
  last_active  date
)
language plpgsql security definer set search_path = public as $$
declare ch challenges%rowtype; d_from date; d_to date;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select * into ch from challenges c where c.code = upper(trim(p_code));
  if not found then raise exception 'No challenge with that code'; end if;

  -- you may only see boards you belong to
  if not exists (select 1 from challenge_members m
                 where m.challenge_id = ch.id and m.user_id = auth.uid()) then
    raise exception 'Join the challenge first';
  end if;

  d_from := greatest(coalesce(p_from, ch.starts), ch.starts);
  d_to   := least(coalesce(p_to, ch.ends), ch.ends);

  return query
    select p.id, p.display_name, p.avatar,
           coalesce(sum(d.points), 0)::bigint,
           count(d.*) filter (where d.kcal_in > 0)::bigint,
           p.streak, p.best_streak, p.badges,
           max(d.date) filter (where d.kcal_in > 0)
    from challenge_members m
    join profiles p on p.id = m.user_id
    left join days d on d.user_id = m.user_id and d.date between d_from and d_to
    where m.challenge_id = ch.id
    group by p.id, p.display_name, p.avatar, p.streak, p.best_streak, p.badges
    order by 4 desc, 5 desc, p.display_name asc;
end $$;
revoke all on function challenge_board(text, date, date) from public;
grant execute on function challenge_board(text, date, date) to authenticated;


-- ═══════════════════════════════════════════════════════════════
--  New sign-ups get a profile row automatically.
-- ═══════════════════════════════════════════════════════════════
create or replace function handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

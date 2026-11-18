-- Stage 0 / migration 2: core tables and the constraints that must hold no
-- matter which code path writes to them.
--
-- Entities: profiles, monuments, captures, capture_reviews (+ game_settings).
-- Hold status is NOT stored anywhere. A monument is held iff an approved
-- capture_review for it has locked_until > now(), evaluated at read time.

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------

create type public.app_role as enum ('player', 'moderator');
create type public.capture_status as enum ('in_progress', 'pending', 'approved', 'rejected');
create type public.review_decision as enum ('approved', 'rejected');

-- ---------------------------------------------------------------------------
-- Game settings: one row. Tunables live here, not in function bodies, so a
-- tester can shorten the lock with one UPDATE and put it back for the demo.
-- ---------------------------------------------------------------------------

create table public.game_settings (
  id boolean primary key default true check (id),
  -- How long an approved capture locks the monument to its player.
  lock_duration interval not null default interval '60 minutes'
    check (lock_duration > interval '0'),
  -- Reported GPS accuracy must be at or below this to start a capture.
  max_accuracy_m real not null default 50 check (max_accuracy_m > 0),
  -- An in_progress capture must get its photo within this window.
  in_progress_ttl interval not null default interval '10 minutes'
    check (in_progress_ttl > interval '0'),
  -- Moderator flag: implied travel speed from the player's previous capture.
  impossible_travel_kmh real not null default 120 check (impossible_travel_kmh > 0),
  -- ...but only when the jump is at least this far (ignores GPS jitter).
  impossible_travel_min_m real not null default 1000 check (impossible_travel_min_m >= 0),
  -- Moderator flag: reported position within this many metres of the pin.
  exact_pin_m real not null default 1 check (exact_pin_m >= 0),
  updated_at timestamptz not null default now()
);

insert into public.game_settings (id) values (true);

-- ---------------------------------------------------------------------------
-- Profiles: one per auth user. Identity always comes from auth.uid().
-- ---------------------------------------------------------------------------

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null
    check (char_length(btrim(display_name)) between 1 and 40),
  role public.app_role not null default 'player',
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Monuments. Clients send and read plain latitude/longitude; the geography
-- point used for distance is derived from them and can never disagree.
-- ---------------------------------------------------------------------------

create table public.monuments (
  id uuid primary key default gen_random_uuid(),
  -- Stable key for seeded monuments so the seed migration is idempotent.
  slug text unique check (slug ~ '^[a-z0-9-]+$'),
  name text not null check (char_length(btrim(name)) between 1 and 120),
  neighborhood text not null default '',
  description text not null default '',
  icon text,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  location extensions.geography(Point, 4326) generated always as (
    extensions.st_setsrid(extensions.st_makepoint(longitude, latitude), 4326)::extensions.geography
  ) stored,
  capture_radius_m integer not null default 100
    check (capture_radius_m between 10 and 500),
  -- Moderators deactivate rather than delete, so capture history stays intact.
  active boolean not null default true,
  -- Campus test monuments: real game rules, but clearly labelled as tests.
  is_test boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index monuments_location_idx on public.monuments using gist (location);

-- ---------------------------------------------------------------------------
-- Captures. Everything the client reported is kept, next to what the server
-- derived from it, so moderators can see both.
-- ---------------------------------------------------------------------------

create table public.captures (
  id uuid primary key default gen_random_uuid(),
  monument_id uuid not null references public.monuments (id),
  player_id uuid not null references public.profiles (id) on delete cascade,
  status public.capture_status not null default 'in_progress',

  -- Client-asserted. Cannot be verified on the web; kept as evidence.
  reported_latitude double precision not null check (reported_latitude between -90 and 90),
  reported_longitude double precision not null check (reported_longitude between -180 and 180),
  reported_position extensions.geography(Point, 4326) generated always as (
    extensions.st_setsrid(extensions.st_makepoint(reported_longitude, reported_latitude), 4326)::extensions.geography
  ) stored,
  reported_accuracy_m real not null check (reported_accuracy_m > 0),

  -- Server-derived (ST_Distance from reported_position to the monument).
  distance_m real not null check (distance_m >= 0),
  -- Server-derived suspicion markers shown to moderators. Never block a capture.
  flags text[] not null default '{}'
    check (flags <@ array['impossible_travel', 'repeated_position', 'exact_pin']::text[]),

  -- Storage object path, set when the photo is attached.
  photo_path text,
  started_at timestamptz not null default now(),
  submitted_at timestamptz,

  -- Lets capture_reviews carry monument_id with a foreign key that keeps it honest.
  unique (id, monument_id),
  -- Lifecycle consistency, independent of which function did the write.
  check ((status = 'in_progress') = (submitted_at is null)),
  check (status = 'in_progress' or photo_path is not null),
  check (submitted_at is null or submitted_at >= started_at)
);

-- A player has at most one capture in progress.
create unique index captures_one_in_progress_per_player
  on public.captures (player_id) where status = 'in_progress';
-- ...and at most one capture of a given monument waiting for review.
create unique index captures_one_pending_per_player_monument
  on public.captures (player_id, monument_id) where status = 'pending';
-- Moderator queue, oldest first.
create index captures_pending_queue_idx
  on public.captures (submitted_at) where status = 'pending';
-- Player history and impossible-travel lookups.
create index captures_player_started_idx on public.captures (player_id, started_at desc);

-- ---------------------------------------------------------------------------
-- Capture reviews. One per capture. Approval sets locked_until.
--
-- THE ONE-HOLDER RULE lives here as an exclusion constraint: two approved
-- reviews of the same monument may not have overlapping lock windows. This
-- holds no matter how many moderators approve at once or which code path
-- inserts the row; a concurrent second insert waits for the first and then
-- fails with SQLSTATE 23P01 (exclusion_violation).
--
-- monument_id is copied from the capture because a constraint cannot look
-- across tables. The composite foreign key guarantees the copy matches.
-- ---------------------------------------------------------------------------

create table public.capture_reviews (
  id uuid primary key default gen_random_uuid(),
  capture_id uuid not null unique,
  monument_id uuid not null,
  moderator_id uuid not null references public.profiles (id),
  decision public.review_decision not null,
  -- Optional on approval; required (3+ characters) on rejection (US-14).
  reason text not null default '',
  reviewed_at timestamptz not null default now(),
  locked_until timestamptz,

  foreign key (capture_id, monument_id)
    references public.captures (id, monument_id) on delete cascade,
  check ((decision = 'approved') = (locked_until is not null)),
  check (locked_until is null or locked_until > reviewed_at),
  check (decision = 'approved' or char_length(btrim(reason)) >= 3),

  constraint one_holder_at_a_time exclude using gist (
    monument_id with =,
    tstzrange(reviewed_at, locked_until, '[)') with &&
  ) where (decision = 'approved')
);

create index capture_reviews_monument_lock_idx
  on public.capture_reviews (monument_id, locked_until desc) where decision = 'approved';

-- ---------------------------------------------------------------------------
-- updated_at maintenance
-- ---------------------------------------------------------------------------

-- Internal helpers live in `private`, which the Data API does not expose, so
-- nothing in it can be called from the browser with rpc().
create schema if not exists private;
revoke all on schema private from public;

create function private.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger monuments_touch_updated_at
  before update on public.monuments
  for each row execute function private.touch_updated_at();

create trigger game_settings_touch_updated_at
  before update on public.game_settings
  for each row execute function private.touch_updated_at();

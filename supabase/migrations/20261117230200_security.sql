-- Stage 0 / migration 3: who can read what. Nobody can write.
--
-- The security model in one sentence: the browser may SELECT some rows, and
-- every change goes through a function called with rpc(). This migration
-- therefore grants SELECT only, and no INSERT / UPDATE / DELETE to anyone the
-- browser can act as (anon, authenticated).
--
-- Two independent layers, both deny-by-default:
--   1. GRANTs. Revoked explicitly, so this works on projects created before
--      and after Supabase's 2026 "no automatic Data API exposure" change.
--   2. Row-level security, enabled on every table, with SELECT policies only.
--
-- Signed-out visitors (anon) get nothing at all: the app requires sign-in.

-- ---------------------------------------------------------------------------
-- Helpers (in `private`, not callable through the API)
-- ---------------------------------------------------------------------------

grant usage on schema private to authenticated;

-- SECURITY DEFINER so policies can check the caller's role without recursing
-- through the profiles policies. search_path is pinned to '' and every name
-- is qualified, so a caller cannot redirect it to look-alike objects.
create function private.is_moderator() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role = 'moderator'
  )
$$;

revoke all on function private.is_moderator() from public;
grant execute on function private.is_moderator() to authenticated;

-- ---------------------------------------------------------------------------
-- Layer 1: grants
-- ---------------------------------------------------------------------------

revoke all on table
  public.game_settings, public.profiles, public.monuments,
  public.captures, public.capture_reviews
from anon, authenticated;

grant select on table
  public.game_settings, public.profiles, public.monuments,
  public.captures, public.capture_reviews
to authenticated;

-- Functions created later must opt in to being callable with rpc().
-- Postgres lets everyone (PUBLIC) execute new functions by default, and a
-- per-schema "revoke" cannot remove that global default, so the first line is
-- deliberately global. It applies to objects created by the role running this
-- migration (postgres, on Supabase). The second line removes Supabase's
-- per-schema grants to the API roles on projects that still have them.
-- Each function in later stages also revokes and grants explicitly.
alter default privileges revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Layer 2: row-level security
-- ---------------------------------------------------------------------------

alter table public.game_settings   enable row level security;
alter table public.profiles        enable row level security;
alter table public.monuments       enable row level security;
alter table public.captures        enable row level security;
alter table public.capture_reviews enable row level security;

-- Settings: any signed-in user (the client shows the lock length).
create policy game_settings_read on public.game_settings
  for select to authenticated using (true);

-- Profiles: your own; moderators see everyone. Holder names on the map come
-- from a read function in Stage 2 that returns display names only.
create policy profiles_read_own_or_moderator on public.profiles
  for select to authenticated
  using (id = (select auth.uid()) or (select private.is_moderator()));

-- Monuments: active ones for everyone signed in; moderators also see inactive.
create policy monuments_read on public.monuments
  for select to authenticated
  using (active or (select private.is_moderator()));

-- Captures: your own; moderators see all.
create policy captures_read_own_or_moderator on public.captures
  for select to authenticated
  using (player_id = (select auth.uid()) or (select private.is_moderator()));

-- Reviews: of your own captures; moderators see all.
create policy capture_reviews_read_own_or_moderator on public.capture_reviews
  for select to authenticated
  using (
    (select private.is_moderator())
    or exists (
      select 1 from public.captures c
      where c.id = capture_reviews.capture_id
        and c.player_id = (select auth.uid())
    )
  );

-- Stage 1 / migration 6: every new account gets a player profile.
--
-- Supabase Auth inserts a row into auth.users on sign-up; this trigger creates
-- the matching public.profiles row in the same transaction, so a signed-in
-- user always has a profile.
--
-- The role is ALWAYS 'player'. Sign-up metadata is client-supplied, so it may
-- only suggest a display name; a "role" in the metadata is ignored. Moderators
-- are promoted by hand with supabase/scripts/make_moderator.sql.
--
-- display_name: the "display_name" from sign-up metadata, trimmed and cut to
-- 40 characters; otherwise the part of the email before the @; otherwise
-- "Player".

create function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  requested text := btrim(coalesce(new.raw_user_meta_data ->> 'display_name', ''));
  from_email text := btrim(split_part(coalesce(new.email, ''), '@', 1));
  chosen text;
begin
  chosen := left(coalesce(nullif(requested, ''), nullif(from_email, ''), 'Player'), 40);
  -- left() can leave trailing spaces after cutting; the check needs 1-40 non-blank chars.
  chosen := coalesce(nullif(btrim(chosen), ''), 'Player');

  insert into public.profiles (id, display_name, role)
  values (new.id, chosen, 'player')
  on conflict (id) do nothing;

  return new;
end $$;

revoke all on function private.handle_new_user() from public;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

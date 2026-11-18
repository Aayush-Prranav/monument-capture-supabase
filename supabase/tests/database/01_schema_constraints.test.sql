-- Stage 0: the database rules that hold no matter which code path writes.
-- Runs as the table owner (bypasses RLS) so it tests constraints, not policies.
-- Everything happens in one transaction and is rolled back.

begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- ---------------------------------------------------------------------------
-- Structure
-- ---------------------------------------------------------------------------

select has_extension('postgis', 'PostGIS is installed');
select has_extension('btree_gist', 'btree_gist is installed');
select tables_are('public',
  array['game_settings', 'profiles', 'monuments', 'captures', 'capture_reviews'],
  'public has exactly the five game tables');

select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  0, 'row-level security is enabled on every public table');

-- ---------------------------------------------------------------------------
-- Seed and geography
-- ---------------------------------------------------------------------------

select is((select count(*)::int from public.monuments), 20, '20 monuments seeded');
select is((select count(*)::int from public.monuments where is_test), 5, '5 of them are campus test monuments');
select is((select count(distinct capture_radius_m)::int from public.monuments), 1, 'one radius for all');
select is((select min(capture_radius_m) from public.monuments), 100, '...and it is 100 m');
select is((select count(*)::int from public.game_settings), 1, 'exactly one settings row');
select is((select lock_duration from public.game_settings), interval '60 minutes', 'default lock is 60 minutes');

select ok(
  (select bool_and(abs(extensions.st_distance(
      location,
      extensions.st_setsrid(extensions.st_makepoint(-73.986456, 40.694177), 4326)::extensions.geography
    ) - 30) < 0.5)
   from public.monuments where is_test),
  'each campus test monument is 30 m (+/- 0.5) from the class point');

select ok(
  (select abs(extensions.st_distance(a.location, b.location) - 35.3) < 1
   from public.monuments a, public.monuments b
   where a.slug = 'test-nyu-makerspace' and b.slug = 'test-nyu-gym'),
  'neighbouring campus monuments are about 35 m apart');

select throws_ok(
  $$ insert into public.monuments (name, latitude, longitude, location)
     values ('x', 1, 1, extensions.st_makepoint(5, 5)::extensions.geography) $$,
  '428C9', null, 'the geography point cannot be written directly; it is derived from lat/lng');

select ok(
  (select extensions.st_y(location::extensions.geometry) = latitude
      and extensions.st_x(location::extensions.geometry) = longitude
   from public.monuments where slug = 'bethesda'),
  'derived point matches latitude/longitude');

update public.monuments set latitude = 40.0 where slug = 'bethesda';
select ok(
  (select extensions.st_y(location::extensions.geometry) = 40.0 from public.monuments where slug = 'bethesda'),
  'moving a monument moves its point');

select throws_ok($$ update public.monuments set capture_radius_m = 5 where slug = 'liberty' $$,
  '23514', null, 'radius below 10 m is refused');
select throws_ok($$ update public.monuments set latitude = 91 where slug = 'liberty' $$,
  '23514', null, 'latitude above 90 is refused');
select throws_ok($$ update public.game_settings set lock_duration = interval '0' $$,
  '23514', null, 'a zero lock duration is refused');

-- ---------------------------------------------------------------------------
-- Fixtures: two players, one moderator, captures on Bethesda and Liberty
-- ---------------------------------------------------------------------------

-- Signing up creates each profile (migration 6); the moderator is promoted after.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'p1@test.dev', '{"display_name":"Player One"}'),
  ('00000000-0000-0000-0000-0000000000a2', 'p2@test.dev', '{"display_name":"Player Two"}'),
  ('00000000-0000-0000-0000-0000000000d1', 'mod@test.dev', '{"display_name":"Mod"}');
update public.profiles set role = 'moderator' where id = '00000000-0000-0000-0000-0000000000d1';

create temp table ids as select
  (select id from public.monuments where slug = 'bethesda') as bethesda,
  (select id from public.monuments where slug = 'liberty')  as liberty;

-- Two pending captures of Bethesda by different players, one of Liberty.
insert into public.captures (id, monument_id, player_id, status, reported_latitude, reported_longitude,
                             reported_accuracy_m, distance_m, photo_path, submitted_at)
select v.id, v.mon, v.player, 'pending', 40.7744, -73.9703, 8, 5, 'p/x.jpg', now()
from ids, lateral (values
  ('00000000-0000-0000-0000-00000000c001'::uuid, ids.bethesda, '00000000-0000-0000-0000-0000000000a1'::uuid),
  ('00000000-0000-0000-0000-00000000c002'::uuid, ids.bethesda, '00000000-0000-0000-0000-0000000000a2'::uuid),
  ('00000000-0000-0000-0000-00000000c003'::uuid, ids.liberty,  '00000000-0000-0000-0000-0000000000a1'::uuid)
) as v(id, mon, player);

-- ---------------------------------------------------------------------------
-- Capture lifecycle
-- ---------------------------------------------------------------------------

select ok(
  (select extensions.st_y(reported_position::extensions.geometry) = reported_latitude
   from public.captures where id = '00000000-0000-0000-0000-00000000c001'),
  'reported position is derived from reported lat/lng');

select throws_ok($$
  insert into public.captures (monument_id, player_id, status, reported_latitude, reported_longitude,
                               reported_accuracy_m, distance_m, submitted_at)
  select liberty, '00000000-0000-0000-0000-0000000000a2', 'pending', 0, 0, 5, 5, now() from ids $$,
  '23514', null, 'a pending capture must have a photo');

select throws_ok($$
  insert into public.captures (monument_id, player_id, status, reported_latitude, reported_longitude,
                               reported_accuracy_m, distance_m, photo_path)
  select liberty, '00000000-0000-0000-0000-0000000000a2', 'pending', 0, 0, 5, 5, 'p/y.jpg' from ids $$,
  '23514', null, 'a pending capture must have submitted_at');

select lives_ok($$
  insert into public.captures (monument_id, player_id, reported_latitude, reported_longitude,
                               reported_accuracy_m, distance_m)
  select liberty, '00000000-0000-0000-0000-0000000000a2', 0, 0, 5, 5 from ids $$,
  'a player can have one capture in progress');

select throws_ok($$
  insert into public.captures (monument_id, player_id, reported_latitude, reported_longitude,
                               reported_accuracy_m, distance_m)
  select bethesda, '00000000-0000-0000-0000-0000000000a2', 0, 0, 5, 5 from ids $$,
  '23505', null, '...but not two');

select throws_ok($$
  insert into public.captures (monument_id, player_id, status, reported_latitude, reported_longitude,
                               reported_accuracy_m, distance_m, photo_path, submitted_at)
  select bethesda, '00000000-0000-0000-0000-0000000000a1', 'pending', 0, 0, 5, 5, 'p/z.jpg', now() from ids $$,
  '23505', null, 'a player cannot have two pending captures of the same monument');

select throws_ok($$
  insert into public.captures (monument_id, player_id, reported_latitude, reported_longitude,
                               reported_accuracy_m, distance_m, flags)
  select bethesda, '00000000-0000-0000-0000-0000000000d1', 0, 0, 5, 5, array['made_up'] from ids $$,
  '23514', null, 'only known moderator flags are allowed');

select throws_ok($$
  insert into public.captures (monument_id, player_id, reported_latitude, reported_longitude,
                               reported_accuracy_m, distance_m)
  select bethesda, '00000000-0000-0000-0000-0000000000d1', 0, 0, 0, 5 from ids $$,
  '23514', null, 'reported accuracy must be positive');

-- ---------------------------------------------------------------------------
-- Reviews
-- ---------------------------------------------------------------------------

select throws_ok($$
  insert into public.capture_reviews (capture_id, monument_id, moderator_id, decision)
  values ('00000000-0000-0000-0000-00000000c001', (select bethesda from ids),
          '00000000-0000-0000-0000-0000000000d1', 'approved') $$,
  '23514', null, 'an approval must set locked_until');

select throws_ok($$
  insert into public.capture_reviews (capture_id, monument_id, moderator_id, decision, reason)
  values ('00000000-0000-0000-0000-00000000c001', (select bethesda from ids),
          '00000000-0000-0000-0000-0000000000d1', 'rejected', '  ') $$,
  '23514', null, 'a rejection needs a reason');

select throws_ok($$
  insert into public.capture_reviews (capture_id, monument_id, moderator_id, decision, locked_until)
  values ('00000000-0000-0000-0000-00000000c001', (select liberty from ids),
          '00000000-0000-0000-0000-0000000000d1', 'approved', now() + interval '1 hour') $$,
  '23503', null, 'the review''s monument must be the capture''s monument');

select lives_ok($$
  insert into public.capture_reviews (capture_id, monument_id, moderator_id, decision, locked_until)
  values ('00000000-0000-0000-0000-00000000c001', (select bethesda from ids),
          '00000000-0000-0000-0000-0000000000d1', 'approved', now() + interval '1 hour') $$,
  'an approval with no reason is accepted');

select throws_ok($$
  insert into public.capture_reviews (capture_id, monument_id, moderator_id, decision, reason)
  values ('00000000-0000-0000-0000-00000000c001', (select bethesda from ids),
          '00000000-0000-0000-0000-0000000000d1', 'rejected', 'second review') $$,
  '23505', null, 'a capture can only be reviewed once');

-- The one-holder rule.
select throws_ok($$
  insert into public.capture_reviews (capture_id, monument_id, moderator_id, decision, locked_until)
  values ('00000000-0000-0000-0000-00000000c002', (select bethesda from ids),
          '00000000-0000-0000-0000-0000000000d1', 'approved', now() + interval '1 hour') $$,
  '23P01', null, 'ONE HOLDER: a second overlapping approval on the same monument is refused');

select lives_ok($$
  insert into public.capture_reviews (capture_id, monument_id, moderator_id, decision, locked_until)
  values ('00000000-0000-0000-0000-00000000c003', (select liberty from ids),
          '00000000-0000-0000-0000-0000000000d1', 'approved', now() + interval '1 hour') $$,
  'approvals on different monuments do not interfere');

select lives_ok($$
  insert into public.capture_reviews (capture_id, monument_id, moderator_id, decision, reason)
  values ('00000000-0000-0000-0000-00000000c002', (select bethesda from ids),
          '00000000-0000-0000-0000-0000000000d1', 'rejected', 'Already held') $$,
  'a rejection on a held monument is fine');

-- An expired lock does not block a new one: a back-dated approval ending
-- before now() and a current approval do not overlap.
insert into public.captures (id, monument_id, player_id, status, reported_latitude, reported_longitude,
                             reported_accuracy_m, distance_m, photo_path, started_at, submitted_at)
select '00000000-0000-0000-0000-00000000c004', (select id from public.monuments where slug = 'grant'),
       '00000000-0000-0000-0000-0000000000a1', 'approved', 0, 0, 5, 5, 'p/old.jpg',
       now() - interval '3 hours', now() - interval '3 hours';
insert into public.capture_reviews (capture_id, monument_id, moderator_id, decision, reviewed_at, locked_until)
select '00000000-0000-0000-0000-00000000c004', (select id from public.monuments where slug = 'grant'),
       '00000000-0000-0000-0000-0000000000d1', 'approved', now() - interval '3 hours', now() - interval '2 hours';

insert into public.captures (id, monument_id, player_id, status, reported_latitude, reported_longitude,
                             reported_accuracy_m, distance_m, photo_path, submitted_at)
select '00000000-0000-0000-0000-00000000c005', (select id from public.monuments where slug = 'grant'),
       '00000000-0000-0000-0000-0000000000a2', 'pending', 0, 0, 5, 5, 'p/new.jpg', now();
select lives_ok($$
  insert into public.capture_reviews (capture_id, monument_id, moderator_id, decision, locked_until)
  values ('00000000-0000-0000-0000-00000000c005', (select id from public.monuments where slug = 'grant'),
          '00000000-0000-0000-0000-0000000000d1', 'approved', now() + interval '1 hour') $$,
  'an expired lock does not block a new holder');

-- A lock ending exactly when the next starts is not an overlap ('[)' ranges).
select is(
  tstzrange(now() - interval '1 hour', now(), '[)') && tstzrange(now(), now() + interval '1 hour', '[)'),
  false, 'back-to-back lock windows do not overlap');

select * from finish();
rollback;

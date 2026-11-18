-- Stage 2: the map read path.

begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'p1@test.dev', '{"display_name":"Player One"}'),
  ('00000000-0000-0000-0000-0000000000a2', 'p2@test.dev', '{"display_name":"Player Two"}'),
  ('00000000-0000-0000-0000-0000000000d1', 'mod@test.dev', '{"display_name":"Mod"}');
update public.profiles set role = 'moderator' where id = '00000000-0000-0000-0000-0000000000d1';

-- Player One holds Bethesda (lock running); Player Two's Grant lock expired.
insert into public.captures (id, monument_id, player_id, status, reported_latitude, reported_longitude,
                             reported_accuracy_m, distance_m, photo_path, started_at, submitted_at)
values
  ('00000000-0000-0000-0000-00000000c001', (select id from public.monuments where slug = 'bethesda'),
   '00000000-0000-0000-0000-0000000000a1', 'approved', 0, 0, 5, 5, 'p/1.jpg', now() - interval '20 minutes', now() - interval '20 minutes'),
  ('00000000-0000-0000-0000-00000000c002', (select id from public.monuments where slug = 'grant'),
   '00000000-0000-0000-0000-0000000000a2', 'approved', 0, 0, 5, 5, 'p/2.jpg', now() - interval '3 hours', now() - interval '3 hours');
insert into public.capture_reviews (capture_id, monument_id, moderator_id, decision, reviewed_at, locked_until) values
  ('00000000-0000-0000-0000-00000000c001', (select id from public.monuments where slug = 'bethesda'),
   '00000000-0000-0000-0000-0000000000d1', 'approved', now() - interval '10 minutes', now() + interval '50 minutes'),
  ('00000000-0000-0000-0000-00000000c002', (select id from public.monuments where slug = 'grant'),
   '00000000-0000-0000-0000-0000000000d1', 'approved', now() - interval '3 hours', now() - interval '2 hours');

update public.monuments set active = false where slug = 'farragut';

create temp table m as
select null::jsonb as as_player, null::jsonb as as_moderator, null::jsonb as as_nobody;
grant all on m to authenticated, anon;

-- ---------------------------------------------------------------------------
-- As Player Two
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a2","role":"authenticated"}', true);
update m set as_player = public.get_map();
reset role;

select is(jsonb_array_length((select as_player -> 'monuments' from m)), 19, 'a player sees the 19 active monuments');
select ok((select (as_player ->> 'server_now')::timestamptz between now() - interval '1 minute' and now() + interval '1 minute' from m),
  'server_now is the database clock');

select is(
  (select x -> 'hold' ->> 'holder_name' from m, jsonb_array_elements(as_player -> 'monuments') x where x ->> 'slug' = 'bethesda'),
  'Player One', 'a running lock shows the holder''s display name (another player''s)');
select is(
  (select x -> 'hold' ->> 'holder_id' from m, jsonb_array_elements(as_player -> 'monuments') x where x ->> 'slug' = 'bethesda'),
  '00000000-0000-0000-0000-0000000000a1', '...and their id');
select ok(
  (select (x -> 'hold' ->> 'locked_until')::timestamptz > now() from m, jsonb_array_elements(as_player -> 'monuments') x where x ->> 'slug' = 'bethesda'),
  '...and when the lock ends');
select is(
  (select jsonb_typeof(x -> 'hold') from m, jsonb_array_elements(as_player -> 'monuments') x where x ->> 'slug' = 'grant'),
  'null', 'an expired lock means free: hold is null, decided by the database clock');
select is(
  (select count(*)::int from m, jsonb_array_elements(as_player -> 'monuments') x where x -> 'hold' <> 'null'::jsonb),
  1, 'exactly one monument is held');
select is(
  (select count(*)::int from m, jsonb_array_elements(as_player -> 'monuments') x where x ->> 'slug' = 'farragut'),
  0, 'players do not see inactive monuments');
select ok(
  (select not (as_player::text ilike '%@test.dev%') from m),
  'no email address appears anywhere in the map');
select ok(
  (select not (as_player::text ilike '%p/1.jpg%') from m),
  'no photo path appears anywhere in the map');
select is(
  (select (x ->> 'capture_radius_m')::int from m, jsonb_array_elements(as_player -> 'monuments') x where x ->> 'slug' = 'liberty'),
  100, 'monuments carry their capture radius');

-- ---------------------------------------------------------------------------
-- As the moderator
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000d1","role":"authenticated"}', true);
update m set as_moderator = public.get_map();
reset role;

select is(jsonb_array_length((select as_moderator -> 'monuments' from m)), 20, 'a moderator also sees the inactive monument');
select is(
  (select (x ->> 'active')::boolean from m, jsonb_array_elements(as_moderator -> 'monuments') x where x ->> 'slug' = 'farragut'),
  false, '...marked inactive');

-- ---------------------------------------------------------------------------
-- Signed out
-- ---------------------------------------------------------------------------
select is(has_function_privilege('anon', 'public.get_map()', 'execute'), false, 'signed-out visitors cannot call get_map');
select is(has_function_privilege('authenticated', 'public.get_map()', 'execute'), true, 'signed-in users can');

-- Even if called with no identity (e.g. by a role that can execute it), it returns nothing.
select set_config('request.jwt.claims', '', true);
select is(jsonb_array_length(public.get_map() -> 'monuments'), 0, 'with no auth.uid() the map is empty');

select * from finish();
rollback;

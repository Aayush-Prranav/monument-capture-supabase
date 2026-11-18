-- Stage 3: starting and cancelling captures on the server.

begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'p1@test.dev', '{"display_name":"Player One"}'),
  ('00000000-0000-0000-0000-0000000000a2', 'p2@test.dev', '{"display_name":"Player Two"}'),
  ('00000000-0000-0000-0000-0000000000a3', 'p3@test.dev', '{"display_name":"Player Three"}'),
  ('00000000-0000-0000-0000-0000000000d1', 'mod@test.dev', '{"display_name":"Mod"}');
update public.profiles set role = 'moderator' where id = '00000000-0000-0000-0000-0000000000d1';

create temp table ids as select
  (select id from public.monuments where slug = 'bethesda') as bethesda,
  (select id from public.monuments where slug = 'liberty')  as liberty,
  (select id from public.monuments where slug = 'grant')    as grant_m,
  (select id from public.monuments where slug = 'alice')    as alice,
  (select id from public.monuments where slug = 'farragut') as farragut;
grant select on ids to authenticated;

update public.monuments set active = false where slug = 'farragut';

-- Bethesda's pin is 40.7744, -73.9703. 0.000449 deg of latitude is ~50 m.
create function pg_temp.as_user(uid text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
$$;
-- Migration 3 makes new functions uncallable until granted; that includes this helper.
grant execute on function pg_temp.as_user(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Refusals (nothing is created)
-- ---------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
set local role authenticated;
select is(public.start_capture((select bethesda from ids), 40.7744, -73.9703, 5) ->> 'code', 'not_a_player',
  'moderators cannot start captures');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select is(public.start_capture((select farragut from ids), 40.7426, -73.9878, 5) ->> 'code', 'monument_unavailable',
  'an inactive monument cannot be captured');
select is(public.start_capture(gen_random_uuid(), 40.7744, -73.9703, 5) ->> 'code', 'monument_unavailable',
  'an unknown monument cannot be captured');
select is(public.start_capture((select bethesda from ids), 91, -73.9703, 5) ->> 'code', 'bad_position', 'latitude out of range');
select is(public.start_capture((select bethesda from ids), 40.7744, -73.9703, 'NaN') ->> 'code', 'bad_position', 'NaN accuracy');
select is(public.start_capture((select bethesda from ids), 40.7744, -73.9703, 0) ->> 'code', 'bad_position', 'zero accuracy');

select is(public.start_capture((select bethesda from ids), 40.7744, -73.9703, 80) ->> 'code', 'inaccurate',
  'accuracy worse than 50 m is refused (checked before distance)');

select is(public.start_capture((select bethesda from ids), 40.775747, -73.9703, 8) ->> 'code', 'too_far',
  '150 m away with a 100 m radius is too far');
select ok((public.start_capture((select bethesda from ids), 40.775747, -73.9703, 8) ->> 'distance_m')::int between 149 and 151,
  '...and the server reports the distance it computed (~150 m)');

reset role;
select is((select count(*)::int from public.captures), 0, 'no refusal created a capture');

-- ---------------------------------------------------------------------------
-- Success: distance computed by the server
-- ---------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
set local role authenticated;
create temp table r1 as select public.start_capture((select bethesda from ids), 40.774849, -73.9703, 8) as res;
reset role;

select is((select res ->> 'ok' from r1), 'true', '50 m away with good GPS starts a capture');
select ok((select (res -> 'capture' ->> 'distance_m')::numeric between 49.5 and 50.5 from r1), 'server-computed distance is ~50 m');
select ok((select (res -> 'capture' ->> 'expires_at')::timestamptz = now() + interval '10 minutes' from r1),
  'the capture must get its photo within 10 minutes');
select is((select status::text from public.captures where id = (select (res -> 'capture' ->> 'id')::uuid from r1)), 'in_progress',
  'the capture is in progress');
select is((select player_id from public.captures where id = (select (res -> 'capture' ->> 'id')::uuid from r1)),
  '00000000-0000-0000-0000-0000000000a2'::uuid, 'the capture belongs to the caller (from auth.uid(), not a parameter)');
select is((select flags from public.captures where id = (select (res -> 'capture' ->> 'id')::uuid from r1)), '{}'::text[],
  'a first, ordinary capture has no flags');

-- Starting again replaces the in-progress capture.
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
set local role authenticated;
select is(public.start_capture((select alice from ids), 40.7755, -73.9666, 8) ->> 'ok', 'true', 'starting another capture works');
reset role;
select is((select count(*)::int from public.captures where player_id = '00000000-0000-0000-0000-0000000000a2' and status = 'in_progress'), 1,
  '...and replaces the previous one (one in progress per player)');

-- ---------------------------------------------------------------------------
-- Held and pending
-- ---------------------------------------------------------------------------
-- Player Two holds Grant; Player One has a pending capture of Liberty.
insert into public.captures (id, monument_id, player_id, status, reported_latitude, reported_longitude,
                             reported_accuracy_m, distance_m, photo_path, started_at, submitted_at)
values
  ('00000000-0000-0000-0000-00000000c0a1', (select grant_m from ids), '00000000-0000-0000-0000-0000000000a2', 'approved',
   40.8134, -73.9631, 5, 5, 'p/g.jpg', now() - interval '2 hours', now() - interval '2 hours'),
  ('00000000-0000-0000-0000-00000000c0a2', (select liberty from ids), '00000000-0000-0000-0000-0000000000a1', 'pending',
   40.6892, -74.0445, 5, 5, 'p/l.jpg', now() - interval '2 hours', now() - interval '2 hours');
insert into public.capture_reviews (capture_id, monument_id, moderator_id, decision, locked_until)
values ('00000000-0000-0000-0000-00000000c0a1', (select grant_m from ids), '00000000-0000-0000-0000-0000000000d1', 'approved', now() + interval '30 minutes');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
set local role authenticated;
create temp table r2 as select public.start_capture((select grant_m from ids), 40.8134, -73.9631, 8) as res;
select is((select res ->> 'code' from r2), 'held', 'a monument held by someone else is refused');
select is((select res ->> 'holder_name' from r2), 'Player Two', '...naming the holder');
select ok((select (res ->> 'locked_until')::timestamptz > now() from r2), '...and when the lock ends');
select is(public.start_capture((select liberty from ids), 40.6892, -74.0445, 8) ->> 'code', 'already_pending',
  'a second capture of a monument waiting for review is refused');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select is(public.start_capture((select grant_m from ids), 40.8134, -73.9631, 8) ->> 'code', 'held_by_you',
  'the holder cannot re-capture to extend their lock');
reset role;

-- ---------------------------------------------------------------------------
-- Moderator flags
-- ---------------------------------------------------------------------------
-- Player One's last capture started at Liberty 1 minute ago; Bethesda is ~10 km away.
update public.captures set started_at = now() - interval '1 minute', submitted_at = now() - interval '1 minute'
where id = '00000000-0000-0000-0000-00000000c0a2';
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
set local role authenticated;
create temp table r3 as select public.start_capture((select bethesda from ids), 40.774849, -73.9703, 8) as res;
reset role;
select is((select res -> 'capture' -> 'flags' from r3), '["impossible_travel"]'::jsonb,
  '10 km in a minute is flagged as impossible travel');

-- Player Three: previous capture exactly on Bethesda's pin an hour ago; starts at the same spot.
insert into public.captures (monument_id, player_id, status, reported_latitude, reported_longitude,
                             reported_accuracy_m, distance_m, photo_path, started_at, submitted_at)
values ((select bethesda from ids), '00000000-0000-0000-0000-0000000000a3', 'rejected',
        40.7744, -73.9703, 5, 0, 'p/b.jpg', now() - interval '1 hour', now() - interval '1 hour');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a3');
set local role authenticated;
create temp table r4 as select public.start_capture((select bethesda from ids), 40.7744, -73.9703, 8) as res;
reset role;
select is((select res -> 'capture' -> 'flags' from r4), '["repeated_position", "exact_pin"]'::jsonb,
  'identical coordinates to the last capture, exactly on the pin: both flagged');
select is((select res ->> 'ok' from r4), 'true', 'flags never block a capture');

-- ---------------------------------------------------------------------------
-- Cancelling
-- ---------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
set local role authenticated;
select is(public.cancel_capture((select (res -> 'capture' ->> 'id')::uuid from r4)), false,
  'a player cannot cancel someone else''s capture');
select is(public.cancel_capture('00000000-0000-0000-0000-00000000c0a1'), false, 'a finished capture cannot be cancelled');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a3');
select is(public.cancel_capture((select (res -> 'capture' ->> 'id')::uuid from r4)), true, 'a player cancels their own capture in progress');
reset role;
select is((select count(*)::int from public.captures where player_id = '00000000-0000-0000-0000-0000000000a3' and status = 'in_progress'), 0,
  '...and it is gone');

-- ---------------------------------------------------------------------------
-- get_game_state
-- ---------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
set local role authenticated;
create temp table gs as select public.get_game_state() as s;
reset role;
select is(jsonb_array_length((select s -> 'monuments' from gs)), 19, 'the game state includes the map');
select is((select (s -> 'settings' ->> 'lock_duration_s')::int from gs), 3600, '...the settings');
select is(jsonb_array_length((select s -> 'my_captures' from gs)), 2, '...and only the caller''s own captures');
select ok((select bool_and(x ->> 'id' in ('00000000-0000-0000-0000-00000000c0a2', (select res -> 'capture' ->> 'id' from r3)))
           from gs, jsonb_array_elements(s -> 'my_captures') x), '...which are Player One''s');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
set local role authenticated;
create temp table gs2 as select public.get_game_state() as s;
reset role;
select is((select x -> 'review' ->> 'decision' from gs2, jsonb_array_elements(s -> 'my_captures') x
           where x ->> 'id' = '00000000-0000-0000-0000-00000000c0a1'), 'approved', 'own captures come with their review');
select is((select x -> 'review' ->> 'moderator_name' from gs2, jsonb_array_elements(s -> 'my_captures') x
           where x ->> 'id' = '00000000-0000-0000-0000-00000000c0a1'), 'Mod', '...and the reviewing moderator''s name');

-- ---------------------------------------------------------------------------
-- Not signed in / not callable
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims', '', true);
select throws_ok($$ select public.start_capture((select bethesda from ids), 40.7744, -73.9703, 5) $$,
  '42501', null, 'start_capture with no identity is refused');
select is(has_function_privilege('anon', 'public.start_capture(uuid, double precision, double precision, double precision)', 'execute'), false,
  'signed-out visitors cannot call start_capture');
select is(has_function_privilege('anon', 'public.get_game_state()', 'execute'), false, 'or get_game_state');

select * from finish();
rollback;

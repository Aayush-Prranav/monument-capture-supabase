-- Stage 0: the browser can read only what it should and write nothing.
-- "Signing in" is done the way Supabase does it: role authenticated plus the
-- JWT claims in request.jwt.claims, which auth.uid() reads.

begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- ---------------------------------------------------------------------------
-- Fixtures (as owner)
-- ---------------------------------------------------------------------------

-- Signing up creates each profile (migration 6); the moderator is promoted after.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', 'p1@test.dev', '{"display_name":"Player One"}'),
  ('00000000-0000-0000-0000-0000000000a2', 'p2@test.dev', '{"display_name":"Player Two"}'),
  ('00000000-0000-0000-0000-0000000000d1', 'mod@test.dev', '{"display_name":"Mod"}');
update public.profiles set role = 'moderator' where id = '00000000-0000-0000-0000-0000000000d1';

insert into public.captures (id, monument_id, player_id, status, reported_latitude, reported_longitude,
                             reported_accuracy_m, distance_m, photo_path, submitted_at)
values
  ('00000000-0000-0000-0000-00000000c001', (select id from public.monuments where slug = 'bethesda'),
   '00000000-0000-0000-0000-0000000000a1', 'rejected', 0, 0, 5, 5, 'p/1.jpg', now()),
  ('00000000-0000-0000-0000-00000000c002', (select id from public.monuments where slug = 'liberty'),
   '00000000-0000-0000-0000-0000000000a2', 'rejected', 0, 0, 5, 5, 'p/2.jpg', now());
insert into public.capture_reviews (capture_id, monument_id, moderator_id, decision, reason) values
  ('00000000-0000-0000-0000-00000000c001', (select id from public.monuments where slug = 'bethesda'),
   '00000000-0000-0000-0000-0000000000d1', 'rejected', 'Blurry'),
  ('00000000-0000-0000-0000-00000000c002', (select id from public.monuments where slug = 'liberty'),
   '00000000-0000-0000-0000-0000000000d1', 'rejected', 'Wrong statue');

update public.monuments set active = false where slug = 'farragut';

-- Objects created after the migrations, to check the default privileges
-- (our project was created with "Automatically expose new tables" ticked).
create function public.zz_probe() returns int language sql as 'select 1';
create table public.zz_probe_table (id bigint generated always as identity primary key);

select is(has_table_privilege('anon', 'public.zz_probe_table', 'select'), false,
  'a table added later is not readable by signed-out visitors');
select is(has_table_privilege('authenticated', 'public.zz_probe_table', 'insert'), false,
  'a table added later is not writable by signed-in users');
select is(has_sequence_privilege('authenticated', 'public.zz_probe_table_id_seq', 'usage'), false,
  'a sequence added later is not usable by signed-in users');
select is(has_function_privilege('anon', 'public.zz_probe()', 'execute'), false,
  'a function added later is not callable by signed-out visitors');

-- ---------------------------------------------------------------------------
-- Signed out (anon): nothing at all
-- ---------------------------------------------------------------------------

set local role anon;
select set_config('request.jwt.claims', '', true);

select throws_ok('select count(*) from public.monuments', '42501', null, 'anon cannot read monuments');
select throws_ok('select count(*) from public.profiles', '42501', null, 'anon cannot read profiles');
select throws_ok('select private.is_moderator()', '42501', null, 'anon cannot reach private helpers');

reset role;

-- ---------------------------------------------------------------------------
-- Player One
-- ---------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);

select is((select count(*)::int from public.monuments), 19, 'player sees the 19 active monuments, not the inactive one');
select is((select count(*)::int from public.profiles), 1, 'player sees only their own profile');
select is((select count(*)::int from public.captures), 1, 'player sees only their own captures');
select is((select count(*)::int from public.capture_reviews), 1, 'player sees only reviews of their own captures');
select is((select count(*)::int from public.game_settings), 1, 'player can read the settings');
select is(private.is_moderator(), false, 'player is not a moderator');

-- Writes: every one refused at the grant layer.
select throws_ok($$ update public.profiles set role = 'moderator' where id = auth.uid() $$,
  '42501', null, 'a player cannot promote themselves to moderator');
select throws_ok($$ update public.profiles set display_name = 'x' where id = auth.uid() $$,
  '42501', null, 'a player cannot edit their profile directly');
select throws_ok($$ insert into public.monuments (name, latitude, longitude) values ('Fake', 0, 0) $$,
  '42501', null, 'a player cannot create monuments');
select throws_ok($$ update public.monuments set active = false $$,
  '42501', null, 'a player cannot edit monuments');
select throws_ok($$
  insert into public.captures (monument_id, player_id, status, reported_latitude, reported_longitude,
                               reported_accuracy_m, distance_m, photo_path, submitted_at)
  select id, auth.uid(), 'pending', 0, 0, 5, 5, 'p/x.jpg', now() from public.monuments limit 1 $$,
  '42501', null, 'a player cannot insert a capture (no "distance_meters: 5")');
select throws_ok($$ update public.captures set status = 'approved' $$,
  '42501', null, 'a player cannot change a capture''s status');
select throws_ok($$ update public.captures set distance_m = 0 $$,
  '42501', null, 'a player cannot change a capture''s distance');
select throws_ok($$ delete from public.captures $$,
  '42501', null, 'a player cannot delete captures');
select throws_ok($$
  insert into public.capture_reviews (capture_id, monument_id, moderator_id, decision, locked_until)
  values ('00000000-0000-0000-0000-00000000c001', (select monument_id from public.captures limit 1),
          auth.uid(), 'approved', now() + interval '1 hour') $$,
  '42501', null, 'a player cannot insert a review (cannot lock a monument to themselves)');
select throws_ok($$ update public.game_settings set lock_duration = interval '100 years' $$,
  '42501', null, 'a player cannot change game settings');

select is(has_function_privilege('authenticated', 'public.zz_probe()', 'execute'), false,
  'new functions in public are not callable until explicitly granted');

reset role;

-- ---------------------------------------------------------------------------
-- Moderator: reads everything, still writes nothing directly
-- ---------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000d1","role":"authenticated"}', true);

select is(private.is_moderator(), true, 'moderator is recognised');
select is((select count(*)::int from public.monuments), 20, 'moderator also sees the inactive monument');
select is((select count(*)::int from public.profiles), 3, 'moderator sees all profiles');
select is((select count(*)::int from public.captures), 2, 'moderator sees all captures');
select is((select count(*)::int from public.capture_reviews), 2, 'moderator sees all reviews');

select throws_ok($$
  insert into public.capture_reviews (capture_id, monument_id, moderator_id, decision, reason)
  values ('00000000-0000-0000-0000-00000000c001', (select monument_id from public.captures limit 1),
          auth.uid(), 'rejected', 'direct insert') $$,
  '42501', null, 'even a moderator cannot write reviews directly (only through decide_capture, Stage 4)');
select throws_ok($$ update public.monuments set name = 'x' $$,
  '42501', null, 'even a moderator cannot edit monuments directly (only through functions, Stage 6)');

reset role;

select * from finish();
rollback;

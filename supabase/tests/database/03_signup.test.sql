-- Stage 1: signing up creates a player profile; nobody can sign up as a moderator.

begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000b1', 'named@test.dev', '{"display_name":"  Ada Lovelace  "}'),
  ('00000000-0000-0000-0000-0000000000b2', 'jo.smith@test.dev', '{}'),
  ('00000000-0000-0000-0000-0000000000b3', 'sneaky@test.dev', '{"display_name":"Sneaky","role":"moderator"}'),
  ('00000000-0000-0000-0000-0000000000b4', 'long@test.dev',
   jsonb_build_object('display_name', repeat('x', 39) || ' ' || repeat('y', 20))),
  ('00000000-0000-0000-0000-0000000000b5', null, '{"display_name":"   "}');

select is((select display_name from public.profiles where id = '00000000-0000-0000-0000-0000000000b1'),
  'Ada Lovelace', 'display name comes from sign-up metadata, trimmed');
select is((select display_name from public.profiles where id = '00000000-0000-0000-0000-0000000000b2'),
  'jo.smith', 'without a display name, the email''s local part is used');
select is((select role::text from public.profiles where id = '00000000-0000-0000-0000-0000000000b3'),
  'player', 'a role in sign-up metadata is ignored: everyone starts as a player');
select is((select char_length(display_name) from public.profiles where id = '00000000-0000-0000-0000-0000000000b4'),
  39, 'long names are cut to 40 characters and trailing spaces dropped');
select is((select display_name from public.profiles where id = '00000000-0000-0000-0000-0000000000b5'),
  'Player', 'blank name and no email falls back to "Player"');
select is((select count(*)::int from public.profiles where id::text like '00000000-0000-0000-0000-0000000000b%'),
  5, 'every new account has exactly one profile');

-- The new user can read their own profile through the API role.
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated"}', true);
select is((select display_name from public.profiles), 'Ada Lovelace', 'a new user can read their own profile');
reset role;

select is(has_function_privilege('authenticated', 'private.handle_new_user()', 'execute'), false,
  'the trigger function cannot be called from the browser');

select * from finish();
rollback;

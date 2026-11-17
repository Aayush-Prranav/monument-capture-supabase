-- Stage 0 / migration 5: turn off "Automatically expose new tables and functions".
--
-- A safety net. A project created with that box ticked makes Postgres grant
-- anon and authenticated full access to every table, sequence and function
-- created later in `public`. Our hosted project (MN Capture) was created with
-- it unticked, so there this is a no-op; it protects any other project these
-- migrations are run on (a teammate's, a fresh test project). Our existing
-- tables are locked down explicitly in migration 3 either way, and every
-- future migration still grants explicitly.
--
-- Applies to objects created by the role running it (postgres on Supabase,
-- which is who runs SQL Editor queries and CLI migrations). Safe to re-run.
--
-- Check afterwards (should return no rows mentioning anon or authenticated):
--   select defaclobjtype, defaclacl from pg_default_acl a
--   join pg_namespace n on n.oid = a.defaclnamespace where n.nspname = 'public';

alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;

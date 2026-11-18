-- Stage 0 / migration 1: extensions.
--
-- PostGIS gives us geography(Point) and ST_Distance in metres on the WGS84
-- spheroid, so the server computes capture distance itself.
-- btree_gist lets the one-holder-per-monument exclusion constraint combine an
-- equality test on monument_id with an overlap test on the lock time range.
--
-- Both go in the `extensions` schema, as Supabase recommends, and every use in
-- later migrations is schema-qualified (extensions.st_distance, ...).
-- Do NOT enable PostGIS from the dashboard into `public` first: if it already
-- exists in another schema, "if not exists" is a no-op and the qualified names
-- below will not resolve.

create extension if not exists postgis with schema extensions;
create extension if not exists btree_gist with schema extensions;

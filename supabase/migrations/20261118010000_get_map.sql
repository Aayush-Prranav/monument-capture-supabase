-- Stage 2 / migration 7: the map's read path.
--
-- get_map() returns every monument the caller may see, each with its CURRENT
-- holder (if any), plus the database clock. Hold status is derived here at
-- read time, against now() on the server: a monument is held iff an approved
-- review of it has locked_until > now(). Nothing about holds is stored.
--
-- Why a function and not plain SELECTs: the map must show WHO holds a
-- monument, but players may not read other players' profiles, captures or
-- reviews (migration 3). This function is SECURITY DEFINER and returns only
-- the holder's id and display name, never their email, other captures or
-- photos.
--
-- Shape (JSON, so the client gets one round trip):
--   { "server_now": "...",
--     "monuments": [ { id, slug, name, neighborhood, description, icon,
--                      latitude, longitude, capture_radius_m, active, is_test,
--                      hold: null | { capture_id, holder_id, holder_name,
--                                     held_since, locked_until } } ] }
-- Players see active monuments; moderators also see inactive ones.

create function public.get_map() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'server_now', now(),
    'monuments', coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', mo.id,
          'slug', mo.slug,
          'name', mo.name,
          'neighborhood', mo.neighborhood,
          'description', mo.description,
          'icon', mo.icon,
          'latitude', mo.latitude,
          'longitude', mo.longitude,
          'capture_radius_m', mo.capture_radius_m,
          'active', mo.active,
          'is_test', mo.is_test,
          'hold', case when h.capture_id is null then null else jsonb_build_object(
            'capture_id', h.capture_id,
            'holder_id', h.player_id,
            'holder_name', h.display_name,
            'held_since', h.reviewed_at,
            'locked_until', h.locked_until
          ) end
        )
        order by mo.is_test, mo.name
      ) filter (where mo.id is not null),
      '[]'::jsonb
    )
  )
  from public.monuments mo
  left join lateral (
    -- At most one row can match: the one_holder_at_a_time constraint forbids
    -- overlapping approved locks on a monument.
    select r.capture_id, c.player_id, p.display_name, r.reviewed_at, r.locked_until
    from public.capture_reviews r
    join public.captures c on c.id = r.capture_id
    join public.profiles p on p.id = c.player_id
    where r.monument_id = mo.id
      and r.decision = 'approved'
      and r.locked_until > now()
    order by r.locked_until desc
    limit 1
  ) h on true
  where (select auth.uid()) is not null
    and (mo.active or (select private.is_moderator()))
$$;

revoke all on function public.get_map() from public, anon;
grant execute on function public.get_map() to authenticated;

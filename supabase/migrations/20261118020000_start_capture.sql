-- Stage 3 / migration 8: starting and cancelling a capture, on the server.
--
-- start_capture() runs the capture checks in order, cheapest first:
--   1. the caller is a player (moderators review, they don't capture)
--   2. the monument exists and is active
--   3. the reported position is well-formed
--   4. reported GPS accuracy is within game_settings.max_accuracy_m
--   5. the distance the SERVER computes (PostGIS, metres on the spheroid)
--      from the reported position to the monument is within its radius
--   6. the monument is not held (by anyone, including the caller)
--   7. the caller has no capture of this monument waiting for review
-- Only then is a capture row created (status in_progress). A player has at
-- most one capture in progress; starting another replaces it.
--
-- The position is client-asserted and cannot be verified on the web. What the
-- server guarantees is that the client cannot assert the RESULT (distance,
-- status). It also records three moderator flags, which never block:
--   impossible_travel  implied speed from the player's previous capture start
--                      is above game_settings.impossible_travel_kmh (and the
--                      jump is at least impossible_travel_min_m)
--   repeated_position  exactly the same coordinates as their previous capture
--   exact_pin          within exact_pin_m of the monument's pin
--
-- Expected refusals return {"ok": false, "code": ..., ...} rather than raising,
-- so the app can explain them. Only "not signed in" raises.
--
-- get_game_state() is the app's single read: the map (get_map) plus the
-- caller's own captures with their reviews.

create function public.start_capture(
  p_monument_id uuid,
  p_latitude double precision,
  p_longitude double precision,
  p_accuracy_m double precision
) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_role public.app_role;
  v_settings public.game_settings;
  v_monument public.monuments;
  v_point extensions.geography;
  v_distance double precision;
  v_holder_id uuid;
  v_holder_name text;
  v_locked_until timestamptz;
  v_prev public.captures;
  v_jump double precision;
  v_hours double precision;
  v_flags text[] := '{}';
  v_capture public.captures;
begin
  if v_uid is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;

  -- Lock the caller's profile: one capture start at a time per player, so a
  -- double tap cannot race the "replace the in-progress capture" step.
  select role into v_role from public.profiles where id = v_uid for update;
  if v_role is null then
    raise exception 'No profile for this account' using errcode = '42501';
  end if;
  if v_role <> 'player' then
    return jsonb_build_object('ok', false, 'code', 'not_a_player');
  end if;

  select * into v_monument from public.monuments where id = p_monument_id;
  if not found or not v_monument.active then
    return jsonb_build_object('ok', false, 'code', 'monument_unavailable');
  end if;

  if p_latitude is null or p_longitude is null or p_accuracy_m is null
     or p_latitude not between -90 and 90 or p_longitude not between -180 and 180
     or p_accuracy_m <= 0 or p_accuracy_m in ('NaN'::float8, 'Infinity'::float8) then
    return jsonb_build_object('ok', false, 'code', 'bad_position');
  end if;

  select * into v_settings from public.game_settings;

  if p_accuracy_m > v_settings.max_accuracy_m then
    return jsonb_build_object('ok', false, 'code', 'inaccurate',
      'accuracy_m', round(p_accuracy_m::numeric), 'max_accuracy_m', v_settings.max_accuracy_m);
  end if;

  v_point := extensions.st_setsrid(extensions.st_makepoint(p_longitude, p_latitude), 4326)::extensions.geography;
  v_distance := extensions.st_distance(v_point, v_monument.location);
  if v_distance > v_monument.capture_radius_m then
    return jsonb_build_object('ok', false, 'code', 'too_far',
      'distance_m', ceil(v_distance), 'radius_m', v_monument.capture_radius_m);
  end if;

  select c.player_id, p.display_name, r.locked_until
    into v_holder_id, v_holder_name, v_locked_until
  from public.capture_reviews r
  join public.captures c on c.id = r.capture_id
  join public.profiles p on p.id = c.player_id
  where r.monument_id = v_monument.id and r.decision = 'approved' and r.locked_until > now()
  order by r.locked_until desc
  limit 1;
  if found then
    return jsonb_build_object('ok', false,
      'code', case when v_holder_id = v_uid then 'held_by_you' else 'held' end,
      'holder_name', v_holder_name, 'locked_until', v_locked_until,
      'distance_m', round(v_distance));
  end if;

  if exists (select 1 from public.captures
             where player_id = v_uid and monument_id = v_monument.id and status = 'pending') then
    return jsonb_build_object('ok', false, 'code', 'already_pending');
  end if;

  -- Moderator flags, against the player's previous capture start.
  select * into v_prev from public.captures
  where player_id = v_uid
  order by started_at desc
  limit 1;
  if found then
    v_jump := extensions.st_distance(v_prev.reported_position, v_point);
    v_hours := greatest(extract(epoch from (now() - v_prev.started_at)), 1) / 3600.0;
    if v_jump >= v_settings.impossible_travel_min_m
       and (v_jump / 1000.0) / v_hours > v_settings.impossible_travel_kmh then
      v_flags := array_append(v_flags, 'impossible_travel');
    end if;
    if v_prev.reported_latitude = p_latitude and v_prev.reported_longitude = p_longitude then
      v_flags := array_append(v_flags, 'repeated_position');
    end if;
  end if;
  if v_distance <= v_settings.exact_pin_m then
    v_flags := array_append(v_flags, 'exact_pin');
  end if;

  delete from public.captures where player_id = v_uid and status = 'in_progress';

  insert into public.captures (monument_id, player_id, reported_latitude, reported_longitude,
                               reported_accuracy_m, distance_m, flags)
  values (v_monument.id, v_uid, p_latitude, p_longitude, p_accuracy_m, v_distance, v_flags)
  returning * into v_capture;

  return jsonb_build_object('ok', true, 'capture', jsonb_build_object(
    'id', v_capture.id,
    'monument_id', v_capture.monument_id,
    'distance_m', round(v_capture.distance_m::numeric, 1),
    'accuracy_m', v_capture.reported_accuracy_m,
    'flags', to_jsonb(v_capture.flags),
    'started_at', v_capture.started_at,
    'expires_at', v_capture.started_at + v_settings.in_progress_ttl
  ));
end $$;

-- Abandon a capture that has not been submitted. Returns whether one was removed.
create function public.cancel_capture(p_capture_id uuid) returns boolean
language plpgsql volatile security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;
  delete from public.captures
  where id = p_capture_id and player_id = (select auth.uid()) and status = 'in_progress';
  return found;
end $$;

-- The caller's own captures (newest first, last 200), each with its review.
create function private.my_captures() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x order by x.started_at desc), '[]'::jsonb)
  from (
    select c.id, c.monument_id, c.player_id, c.status, c.distance_m, c.reported_accuracy_m, c.flags,
           c.photo_path, c.started_at, c.submitted_at,
           c.started_at + s.in_progress_ttl as expires_at,
           case when r.id is null then null else jsonb_build_object(
             'id', r.id, 'decision', r.decision, 'reason', r.reason,
             'reviewed_at', r.reviewed_at, 'locked_until', r.locked_until,
             'moderator_id', r.moderator_id, 'moderator_name', mp.display_name
           ) end as review
    from public.captures c
    cross join public.game_settings s
    left join public.capture_reviews r on r.capture_id = c.id
    left join public.profiles mp on mp.id = r.moderator_id
    where c.player_id = (select auth.uid())
    order by c.started_at desc
    limit 200
  ) x
$$;

-- Everything the app needs in one round trip, consistent at one instant.
create function public.get_game_state() returns jsonb
language sql stable security definer set search_path = '' as $$
  select public.get_map() || jsonb_build_object(
    'settings', (select jsonb_build_object(
                   'lock_duration_s', extract(epoch from lock_duration)::int,
                   'max_accuracy_m', max_accuracy_m,
                   'in_progress_ttl_s', extract(epoch from in_progress_ttl)::int)
                 from public.game_settings),
    'my_captures', private.my_captures()
  )
  where (select auth.uid()) is not null
$$;

revoke all on function public.start_capture(uuid, double precision, double precision, double precision) from public, anon;
revoke all on function public.cancel_capture(uuid) from public, anon;
revoke all on function private.my_captures() from public, anon;
revoke all on function public.get_game_state() from public, anon;
grant execute on function public.start_capture(uuid, double precision, double precision, double precision) to authenticated;
grant execute on function public.cancel_capture(uuid) to authenticated;
grant execute on function public.get_game_state() to authenticated;

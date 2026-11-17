-- Stage 0 / migration 4: the monument catalogue.
--
-- A migration rather than supabase/seed.sql because seed.sql only runs on a
-- local `supabase db reset`; it never reaches the hosted project.
-- Idempotent: re-running it changes nothing (keyed on slug).
--
-- Every monument uses the universal 100 m capture radius (team decision,
-- 17 Nov). The column stays per-monument so the moderator editor still works.
--
-- NYC coordinates come from mobile/src/demo/seed.ts (4 decimal places, about
-- 11 m). They have not been checked against a map yet.

insert into public.monuments
  (slug, name, neighborhood, description, icon, latitude, longitude, is_test)
values
  ('liberty', 'Statue of Liberty', 'Liberty Island', 'Copper colossus in New York Harbor, dedicated 1886.', '🗽', 40.6892, -74.0445, false),
  ('washington-arch', 'Washington Square Arch', 'Greenwich Village', 'Marble triumphal arch at the foot of Fifth Avenue.', '🏛️', 40.7312, -73.9971, false),
  ('soldiers-sailors', 'Soldiers'' and Sailors'' Arch', 'Prospect Heights', 'Civil War memorial arch at Grand Army Plaza.', '🎖️', 40.673, -73.97, false),
  ('brooklyn-war', 'Brooklyn War Memorial', 'Downtown Brooklyn', 'Memorial to Brooklyn''s WWII dead in Cadman Plaza.', '🕊️', 40.7005, -73.9897, false),
  ('grant', 'General Grant National Memorial', 'Morningside Heights', 'The largest mausoleum in North America.', '⚱️', 40.8134, -73.9631, false),
  ('bethesda', 'Bethesda Fountain', 'Central Park', 'Angel of the Waters, centrepiece of Bethesda Terrace.', '⛲', 40.7744, -73.9703, false),
  ('obelisk', 'Cleopatra''s Needle', 'Central Park', 'Ancient Egyptian obelisk behind the Met.', '🏺', 40.7796, -73.9654, false),
  ('columbus', 'Columbus Monument', 'Columbus Circle', 'Granite column at the southwest corner of Central Park.', '🧭', 40.7681, -73.9819, false),
  ('flatiron-worth', 'Worth Monument', 'Flatiron District', 'Obelisk and tomb of General William Jenkins Worth.', '⚔️', 40.7425, -73.9898, false),
  ('charging-bull', 'Charging Bull', 'Financial District', 'Bronze bull on Broadway at Bowling Green.', '🐂', 40.7056, -74.0134, false),
  ('federal-hall', 'George Washington at Federal Hall', 'Financial District', 'Statue marking the site of Washington''s 1789 inauguration.', '🎩', 40.7073, -74.0104, false),
  ('alice', 'Alice in Wonderland', 'Central Park', 'Bronze sculpture near Conservatory Water.', '🐇', 40.7755, -73.9666, false),
  ('imagine', 'Strawberry Fields ''Imagine'' Mosaic', 'Central Park', 'Memorial mosaic near the Dakota.', '☮️', 40.7757, -73.975, false),
  ('prison-ship', 'Prison Ship Martyrs'' Monument', 'Fort Greene', 'Doric column honouring Revolutionary War prisoners.', '⚓', 40.6915, -73.9755, false),
  ('farragut', 'Admiral Farragut Monument', 'Madison Square', 'Saint-Gaudens bronze in Madison Square Park.', '⛵', 40.7426, -73.9878, false),
  -- Campus test monuments: five points 30 m from 40.694177, -73.986456, 72
  -- degrees apart. The names are labels for testing; these are NOT the real
  -- locations of the buildings. Neighbours are about 35 m apart, so with a
  -- 100 m radius a player near the centre is in range of all five.
  ('test-nyu-makerspace', 'NYU Makerspace (test)', 'Downtown Brooklyn', 'Campus test monument. Not at the real building.', '🛠️', 40.694446, -73.986456, true),
  ('test-nyu-gym', 'NYU Gym (test)', 'Downtown Brooklyn', 'Campus test monument. Not at the real building.', '🏋️', 40.694260, -73.986118, true),
  ('test-nyu-library', 'NYU Library (test)', 'Downtown Brooklyn', 'Campus test monument. Not at the real building.', '📚', 40.693959, -73.986247, true),
  ('test-nyu-dining-hall', 'NYU Dining Hall (test)', 'Downtown Brooklyn', 'Campus test monument. Not at the real building.', '🍽️', 40.693959, -73.986665, true),
  ('test-blank-street-coffee', 'Blank Street Coffee (test)', 'Downtown Brooklyn', 'Campus test monument. Not at the real building.', '☕', 40.694260, -73.986794, true)
on conflict (slug) do nothing;

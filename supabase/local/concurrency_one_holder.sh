#!/usr/bin/env bash
# LOCAL TESTING ONLY. The one-holder rule under real concurrency.
#
# N separate database sessions each approve a DIFFERENT pending capture of the
# SAME monument, all starting at the same instant and holding their
# transactions open for a second so they genuinely overlap. Exactly one may
# succeed; every other one must fail with 23P01 (exclusion_violation).
#
# Stage 0 inserts the review rows directly (as the owner) to test the
# constraint itself. Stage 4 repeats this through decide_capture().
set -euo pipefail

db="${1:-monument_test}"
n="${N:-12}"
psql_db=(psql -X -q -v ON_ERROR_STOP=1 -d "$db")
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

"${psql_db[@]}" <<SQL
delete from public.capture_reviews;
delete from public.captures;
delete from public.profiles where id in (select id from auth.users where email like 'race%@test.dev');
delete from auth.users where email like 'race%@test.dev';

insert into auth.users (id, email, raw_user_meta_data)
select gen_random_uuid(), 'race' || g || '@test.dev', jsonb_build_object('display_name', 'race' || g || '@test.dev')
from generate_series(0, $n) g;
update public.profiles set role = 'moderator' where display_name = 'race0@test.dev';

insert into public.captures (monument_id, player_id, status, reported_latitude, reported_longitude,
                             reported_accuracy_m, distance_m, photo_path, submitted_at)
select (select id from public.monuments where slug = 'bethesda'), p.id, 'pending',
       40.7744, -73.9703, 8, 5, 'race/' || p.id || '.jpg', now()
from public.profiles p where p.role = 'player' and p.display_name like 'race%';
SQL

mapfile -t captures < <("${psql_db[@]}" -Atc "
  select c.id from public.captures c join public.profiles p on p.id = c.player_id
  where p.display_name like 'race%' order by c.id")
moderator="$("${psql_db[@]}" -Atc "select id from public.profiles where display_name = 'race0@test.dev'")"
start_at="$("${psql_db[@]}" -Atc "select (clock_timestamp() + interval '2 seconds')::text")"

echo "  ${#captures[@]} sessions approving different captures of Bethesda Fountain at $start_at"

i=0
for capture in "${captures[@]}"; do
  i=$((i + 1))
  (
    if psql -X -q -v ON_ERROR_STOP=1 -d "$db" >"$tmp/out.$i" 2>&1 <<SQL
select pg_sleep_until('$start_at');
begin;
insert into public.capture_reviews (capture_id, monument_id, moderator_id, decision, locked_until)
select id, monument_id, '$moderator', 'approved', now() + interval '1 hour'
from public.captures where id = '$capture';
select pg_sleep(1);
commit;
SQL
    then echo ok >"$tmp/result.$i"
    elif grep -q 'one_holder_at_a_time' "$tmp/out.$i"; then echo blocked >"$tmp/result.$i"
    else echo error >"$tmp/result.$i"
    fi
  ) &
done
wait

ok=$(cat "$tmp"/result.* | grep -cx 'ok' || true)
blocked=$(cat "$tmp"/result.* | grep -cx 'blocked' || true)
errors=$(cat "$tmp"/result.* | grep -cx 'error' || true)
holders="$("${psql_db[@]}" -Atc "
  select count(*) from public.capture_reviews r join public.monuments m on m.id = r.monument_id
  where m.slug = 'bethesda' and r.decision = 'approved' and r.locked_until > now()")"

echo "  committed: $ok   refused by one_holder_at_a_time: $blocked   other errors: $errors"
echo "  active holders of Bethesda Fountain: $holders"

"${psql_db[@]}" -c "delete from public.capture_reviews; delete from public.captures;"

if [[ "$ok" == 1 && "$holders" == 1 && "$errors" == 0 && "$blocked" == $((${#captures[@]} - 1)) ]]; then
  echo "  PASS: exactly one holder"
else
  echo "  FAIL"; cat "$tmp"/out.* >&2; exit 1
fi

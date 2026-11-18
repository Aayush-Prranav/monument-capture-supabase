# Working on Monument Capture (team guide)

`main` is the shared branch. Nobody pushes to it directly: every change goes through a branch and a pull request (PR), and a PR merges only when CI is green and one other person has approved it.

## Branches

- Start every branch from an up-to-date `main` and name it `dev_<name>_<topic>`, e.g. `dev_iris_auth`. Delete it after it's merged.
- **Old branches:** `playground`, `prestaging`, `prod`, `non_demo`, `mvp_with_6mtc`, `iris-dev` and the `dev_*_US_*` branches hold the earlier local-only demo.
  - They're kept for reference only (each also has an `archive/<name>` tag). Don't branch from them, open PRs into them, or merge them into `main`.
  - To bring something across from an old branch, rebuild it on current `main`.

## The five parts (do these first, in order)

`main` starts as a skeleton (see the README). Each person adds one part with one PR. The parts build on each other, so **merge them in this order**, and start yours only after the one before it is merged:

1. Iris: accounts and sign-in
2. Bill: map from the server
3. Jason: starting a capture on the server, and deployment
4. Aayush: photos and moderation
5. Yuming: monument management and ending holds early

Aayush gives each of you a folder for your part. It holds the files to copy in, a commit message and a PR description.

```bash
git switch main && git pull                  # must include the previous part
git switch -c dev_<name>_<part>              # e.g. dev_bill_map_sync
# copy everything inside your folder's files/ into the repo root, replacing existing files
cd mobile && npm ci && npm run typecheck && npm test && cd ..
git add -A && git status                     # only your part's files should be listed
git commit -F <your folder>/COMMIT_MSG.txt
git push -u origin dev_<name>_<part>
```

Then open the PR into `main` on GitHub and paste in `PR.md`. Ask the next person in line to review it, and merge once CI is green and it's approved.

The database migrations in these parts are **already applied** to the live Supabase project. Don't run them there again.

## Who owns what (after the five parts)

| Person | Area | Main files |
|---|---|---|
| Iris | Accounts and sign-in | `mobile/src/auth/`, `mobile/app/login.tsx`, `profile_on_signup` migration |
| Bill | Map data and sync; checking the 15 NYC monument pins | `mobile/src/backend/serverMap.ts`, `mapSync.ts`, `get_map` and `seed_monuments` migrations |
| Jason | Starting a capture, moderator flags, deploy; next: accuracy flag and rate limit | `mobile/app/capture.tsx`, `start_capture` migration, `.github/workflows/` |
| Aayush | Photos, moderation, integration (merges and conflicts) | `capture_photos` and `decide_capture` migrations, `mobile/app/review/` |
| Yuming | Hold status, monument details and management, hold history | `mobile/app/monuments/`, `mobile/app/manage-monument/`, `manage_monuments` and `release_hold` migrations |

`mobile/src/backend/game.ts` and `mobile/src/demo/store.ts` are shared. Keep changes there small and say so in the PR. Whoever owns an area reviews PRs that touch it.

## Setup

```bash
git clone https://github.com/SWE-1-GROUP-3/Monument_Capture.git
cd Monument_Capture/mobile
npm ci
npm run web
```

After part 1, `cp .env.example .env` connects the app to the shared Supabase project. The file holds only the publishable key, which is meant to be public.

Never commit `mobile/.env`. Never put the Supabase **secret** key, the `service_role` key or the database password anywhere in the repo.

## Database changes (after the five parts)

- A database change is a **new file** in `supabase/migrations/`. Never edit a migration that's already in `main`.
- Name it `YYYYMMDDHHMMSS_what_it_does.sql`, later than the newest file there. Use the current time so two people don't pick the same name.
- Follow the existing pattern:
  - Tables are read-only to the app. Every write is a `public` function called with `rpc()`.
  - Each function is `security definer`, uses `set search_path = ''` and fully qualified names, and grants `execute` to `authenticated` only.
  - Helpers go in the `private` schema.
  - New tables get row-level security.
- Add pgTAP tests in `supabase/tests/database/` and run `supabase/local/run_local.sh` before opening the PR. CI runs it too.
- After the PR merges, Aayush applies the migration to the live project in the SQL Editor and records it in `supabase/README.md`. One person applying keeps the live database matching `main`.

## Accounts

Sign up on the site to get a player account. To make someone a moderator, Aayush runs `supabase/scripts/make_moderator.sql` with their email. Don't share passwords in the group chat or in the repo.

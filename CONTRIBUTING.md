# Working on Monument Capture (team guide)

`main` is the working game: Supabase backend (`supabase/`) plus the Expo web app (`mobile/`).
Nobody pushes to `main` directly. Every change goes through a branch and a pull request.

## Branches

- `main` is the only shared branch. Start every branch from it and open every PR into it. A merge to `main` redeploys the live site.
- `dev_<name>_<topic>` branches are yours. Delete them once they're merged.
- **Old branches:** `playground`, `prestaging`, `prod`, `non_demo`, `mvp_with_6mtc`, `iris-dev`, and the `dev_*_US_*` branches all hold the earlier local-only demo (no server, fake sign-in).
  - Don't branch from them or merge them into `main`. To bring a feature across, rebuild it on current `main`.
  - Planned cleanup, once the team agrees: each shared old branch gets a tag (e.g. `archive/playground`) and is then deleted. The code and PR history stay reachable through the tag.
  - Personal `dev_*` branches are left for their owners to delete.

## Who owns what

Each person owns an area: you build in it, and you review PRs that touch it.

| Person | Area | Main files |
|---|---|---|
| Iris | Accounts and sign-in | `mobile/src/auth/`, `mobile/app/login.tsx`, `profile_on_signup` migration |
| Bill | Map data and sync, checking the 15 NYC monument pins | `mobile/src/backend/serverMap.ts`, `mapSync.ts`, `get_map` / `seed_monuments` migrations |
| Yuming | Hold status, monument details, monument management, hold history | `mobile/app/monuments/`, `mobile/app/manage-monument/`, `manage_monuments` / `release_hold` migrations |
| Jason | Starting a capture, moderator flags, deploy; next: accuracy flag and rate limit | `mobile/app/capture.tsx`, `start_capture` migration, `.github/workflows/` |
| Aayush | Photos, moderation, integration (merges and conflicts) | `capture_photos` / `decide_capture` migrations, `mobile/app/review/`, `mobile/src/backend/game.ts` |

`mobile/src/backend/game.ts` and `mobile/src/demo/store.ts` are shared. Keep changes there small and say so in the PR.

## First time

```bash
git clone https://github.com/SWE-1-GROUP-3/Monument_Capture.git
cd Monument_Capture/mobile
npm ci
cp .env.example .env        # already points at the shared Supabase project (publishable key only)
npm run web
```

Never commit `mobile/.env`. Never put the Supabase **secret** key, `service_role` key or database password anywhere in the repo. Only the `sb_publishable_…` key belongs in the app.

## Every change

```bash
git switch main && git pull
git switch -c dev_<name>_<short-topic>      # e.g. dev_iris_password_reset
# ...work, commit...
cd mobile && npm run typecheck && npm test  # must pass
git push -u origin dev_<name>_<short-topic>
```

Then open a PR into `main` on GitHub and fill in the template. A PR merges when:
- the **CI** check is green (app typecheck and tests, plus database tests), and
- one other person has approved it (the owner of the area it touches, if that's not you).

Keep PRs small: one feature or fix each. If `main` moved on, run `git pull origin main` on your branch, fix any conflicts, and push again.

## Database changes

- A change to the database is a **new file** in `supabase/migrations/`. Never edit a migration that has already been applied; write a new one that changes it.
- Name it `YYYYMMDDHHMMSS_what_it_does.sql`, later than the newest one there (currently `20261118060000_release_hold.sql`). Use the time you create it so two people don't pick the same name.
- Rules every migration follows (the existing ones show how):
  - Tables are read-only to the app. Every write goes through a `public` function called with `rpc()`.
  - Functions are `security definer`, `set search_path = ''`, use fully qualified names, and are granted `execute` to `authenticated` only.
  - Helpers go in the `private` schema.
  - New tables get row-level security and an explicit `grant select … to authenticated` if the app reads them.
- Add pgTAP tests in `supabase/tests/database/` (next number after the existing files).
- Run the database tests locally before opening the PR (Postgres 16 with PostGIS and pgTAP):
  ```bash
  supabase/local/run_local.sh
  ```
  CI runs the same script on every PR.
- **Applying to the shared project:** only after the PR is merged, and only by Aayush (or whoever the team picks). Paste the file into the Supabase SQL Editor and run it, then tick it off in the table in `supabase/README.md`. One person applying avoids two people half-applying different versions.

## Accounts for testing

Use your own account on the live site; sign-up is open and makes you a player. To make someone a moderator, Aayush runs `supabase/scripts/make_moderator.sql` with their email. Don't share passwords in the group chat or in the repo.

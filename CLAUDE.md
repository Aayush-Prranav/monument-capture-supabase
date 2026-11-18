# Notes for Claude (and anyone new)

Read `CONTRIBUTING.md` first: area owners, branch + PR flow, migration rules. `README.md` explains how the app and backend fit together.

Rules that are easy to break:

- Never commit to or push `main`. Work on a `dev_<name>_<topic>` branch and open a PR. Ask the person before committing or pushing.
- The backend is Supabase. Tables are read-only to the app. Every write is a `public` Postgres function called with `rpc()` and checked on the server (distance, GPS accuracy, holds, roles). Don't move game rules into the app, and don't add client-side `insert`/`update` calls.
- Database changes are new files in `supabase/migrations/`, timestamped after the newest one. Never edit an existing migration. Follow the existing pattern: `security definer`, `set search_path = ''`, fully qualified names, `execute` granted to `authenticated` only, helpers in `private`. Add pgTAP tests in `supabase/tests/database/`.
- Don't run SQL against the hosted project, and don't give instructions to. Migrations are applied by one person after merge.
- Secrets: only the `sb_publishable_…` key may appear in code. Never the secret key, `service_role` or the database password. Never commit `mobile/.env`.
- The old branches (`playground`, `dev_*_US_*`, `mvp_with_6mtc`, …) use the earlier local-only demo design. Don't merge them into `main`. Port the feature onto current `main`, going through `mobile/src/backend/game.ts` and a migration where the server must decide.
- Before opening a PR: `cd mobile && npm run typecheck && npm test`, and `supabase/local/run_local.sh` if the database changed.

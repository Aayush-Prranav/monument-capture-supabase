# Monument Capture (Supabase build)

A web game where players claim real-world monuments by travelling to them.
A player starts a capture at a monument, photographs it, and a moderator
approves or rejects it. An approved capture locks the monument to that player
for a fixed time; holding monuments is the win condition.

This repository is the Supabase backend build of the CS-GY 6063 team project
[SWE-1-GROUP-3/Monument_Capture](https://github.com/SWE-1-GROUP-3/Monument_Capture),
started from its `dev_aayush_demo_mvp_1.0` branch with full history.

**Play it:** https://aayush-prranav.github.io/monument-capture-supabase/
(redeployed automatically on every push to `main`; see "Deployment" below).

## Layout

| Path | What it is |
|---|---|
| `mobile/` | The app: Expo + React Native + TypeScript, built for the web. (Named `mobile/` for historical reasons.) |
| `supabase/` | The database: migrations, tests, scripts. See [supabase/README.md](supabase/README.md). |
| `backend/` | The original Spring Boot skeleton (health endpoint only). Not used by the Supabase build. |

## How it is put together

- **The browser can read, never write.** Tables are read-only to the client
  (grants + row-level security). Every change will go through a Postgres
  function called with `rpc()`, so the client can never assert a distance,
  a status or a lock.
- **The server computes.** Capture distance comes from PostGIS on the server;
  identity comes from `auth.uid()`, never from a client-supplied id.
- **Hold status is derived, not stored.** A monument is held while an approved
  review's `locked_until` is in the future, by the database clock.
- **One holder per monument is a database rule** (an exclusion constraint), so
  two moderators approving at the same instant still produce exactly one holder.
- **Location cannot be verified on the web.** The position is client-asserted;
  the server check stops casual tampering, and presence is established by the
  moderator's photo review (and, later, the server-issued challenge).

## Progress

| Stage | What | Status |
|---|---|---|
| 0 | Schema, one-holder constraint, RLS, monument seed | Done, applied to the hosted project |
| 1 | Real sign-up and login, profile created on sign-up, moderator script | Done |
| 2 | Map reads monuments and holds from the server (`get_map()`), server clock | Done |
| 3 | `start_capture` / `cancel_capture` with server-side distance and moderator flags | Done |
| 4 | Photo upload to Supabase Storage, `submit_capture` | Done |
| 5 | `decide_capture` moderator transaction and review queue | Done |
| 6 | Monument management for moderators (`save_monument`, `set_monument_active`), deployment to GitHub Pages | Done |
| + | Moderators can end a hold early (`release_hold`), with a reason the player sees | Done |

Until a stage lands, that part of the game still runs on the local store in
the browser, behind the backend switch below.

## Running the app

Needs Node.js 22.13+ (22.x), 24.3+ or 26+.

```bash
cd mobile
cp .env.example .env     # already points at the MN Capture project
npm ci
npm run web
```

Open the address Expo prints (usually http://localhost:8081). Browser location
and camera need `localhost` or HTTPS.

### Backend switch (`mobile/.env`)

| Variable | Values | Effect |
|---|---|---|
| `EXPO_PUBLIC_BACKEND` | `supabase` / `local` | `supabase`: real accounts. `local`: the original all-in-browser demo with demo accounts (password `demo123`). |
| `EXPO_PUBLIC_SUPABASE_URL`, `EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | from the Supabase dashboard | Public by design. **Never** put the secret key or database password in the app. |
| `EXPO_PUBLIC_DEV_TOOLS` | `true` / `false` | Demo tools (fake location, fast-forward clock, reset) in Supabase mode. Always on in local mode. Keep `false` for public deploys. |

Changing `.env` needs a restart of `npm run web`.

### Accounts (Supabase mode)

- **Sign up** on the login screen ("New here? Create an account"). Email
  confirmation is off for the course, so the account works immediately.
- Every new account is a **player**. To make someone a moderator, run
  [supabase/scripts/make_moderator.sql](supabase/scripts/make_moderator.sql) in
  the Supabase SQL Editor with their email; they see the change at next login.

### Testing without being at a monument

Location can't be verified on the web anyway, so faking it for testing weakens
nothing. Options: Chrome DevTools → ⋮ → More tools → **Sensors** → Location
(no app code involved); `EXPO_PUBLIC_DEV_TOOLS=true` for the in-app tools; or
the five campus test monuments around 40.694177, -73.986456 (labelled "(test)").

## Deployment

`.github/workflows/deploy-pages.yml` runs on every push to `main`: typecheck,
tests, then a web build in Supabase mode with demo tools **off**, published to
GitHub Pages over HTTPS (browsers only allow location and camera on HTTPS).
`EXPO_BASE_URL` puts the build under the repo's subpath; it is unset locally.

The workflow contains only the project URL and publishable key, which are
public by design. Never add the secret key or the database password to it.

### Vercel (alternative host)

`mobile/vercel.json` holds the build settings (build `npx expo export -p web`,
output `dist`, every unknown path served by `index.html`). In Vercel: import
the repo, set **Root Directory** to `mobile`, and add these environment
variables: `EXPO_PUBLIC_BACKEND=supabase`, `EXPO_PUBLIC_SUPABASE_URL`,
`EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, `EXPO_PUBLIC_DEV_TOOLS=false`.
Vercel serves from the root, so `EXPO_BASE_URL` stays unset there.

## Checks

```bash
cd mobile
npm run typecheck
npm test                       # Vitest

cd ..
supabase/local/run_local.sh    # database tests on a local Postgres (see supabase/README.md)
```

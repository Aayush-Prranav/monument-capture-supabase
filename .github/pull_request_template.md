## What this changes

<!-- One or two sentences. Link the user story or issue (e.g. US-05). -->

## Area

- [ ] Accounts (Iris)
- [ ] Map data and sync (Bill)
- [ ] Holds and monument management (Yuming)
- [ ] Capturing, flags, deploy (Jason)
- [ ] Photos and moderation (Aayush)
- [ ] Shared files (`game.ts`, `store.ts`): explained below

## Checks

- [ ] `npm run typecheck` and `npm test` pass in `mobile/`
- [ ] Database change? New migration file (no edits to old ones) and pgTAP tests added; `supabase/local/run_local.sh` passes
- [ ] No secrets: no `.env`, no secret key, no `service_role`, no database password

## Design choices

<!-- Anything you decided that wasn't specified, and what the alternative was (for the decision records). -->

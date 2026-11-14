# Budgy API

A Cloudflare Worker (TypeScript) with a D1 database. It signs people in with Apple, keeps each
person's Budgy data so it survives reinstalls and syncs across devices, and talks to Plaid so bank
keys never live on a phone. Everything runs on Cloudflare's free plan.

## Environments

| | Production | Dev |
|---|---|---|
| Worker | `budgy` | `budgy-dev` |
| URL | https://budgy.thebudgyapp.workers.dev | https://budgy-dev.thebudgyapp.workers.dev |
| Plaid | production | sandbox |
| D1 | `budgy-prod` | `budgy-dev` |
| Deploys | Workers Builds, on every push to `main` (`npm run deploy`) | from a Mac: `npm run deploy:dev` |

Both deploy commands apply new D1 migrations first, then deploy the worker. All configuration lives
in `wrangler.toml`; the only values set by hand are the secrets below.

## Setup on a Mac

```sh
cd Server
npm install
npx wrangler login
npm test            # runs inside the Workers runtime with a local D1; Plaid and Apple are mocked
npm run deploy:dev
npm run e2e:dev     # end-to-end check of budgy-dev against Plaid's sandbox
```

## Secrets

Set with `npx wrangler secret put NAME` (add `--env dev` for dev). Never paste them into chat or git.

| Secret | What it is |
|---|---|
| `PLAID_CLIENT_ID`, `PLAID_SECRET` | Plaid keys (production secret for prod, sandbox secret for dev) |
| `TOKEN_KEYS` | AES-256 keys that encrypt Plaid access tokens and Apple refresh tokens in D1, as JSON `{"1": "<base64>"}`. **Production's is backed up in the Mac's login Keychain as "Budgy production TOKEN_KEYS"**; losing it means re-linking every bank. |
| `SESSION_SIGNING_KEY` | Signs Budgy's one-hour access tokens (losing it just signs everyone out) |
| `APPLE_SIWA_PRIVATE_KEY` | The Sign in with Apple key (`AuthKey_VGLUZ6H3NV.p8` in `~/.appstoreconnect/private_keys/`) |
| `LEGACY_OWNER_USER_ID` | Production only: the account allowed to claim the old relay's bank connections |
| `DEV_TEST_LOGIN_SECRET` | Dev only: enables `/dev/login` for scripted tests (copy kept in `Server/.dev.vars`) |
| `APP_TOKEN` | Leftover from the old relay; unused, delete during cleanup |

## API

All bodies are JSON. Errors look like `{"error": {"code": "…", "message": "…"}}`.

| Route | Auth | Purpose |
|---|---|---|
| `GET /health` | – | Environment and deployed version |
| `POST /auth/apple` | – | Sign in with Apple: `identity_token`, `raw_nonce`, `authorization_code`, optional `full_name`, `time_zone` |
| `POST /auth/refresh` | – | Rotate the refresh token, get a new access token |
| `POST /auth/signout` | – | End this device's session |
| `GET /me`, `DELETE /me` | ✓ | Profile; delete the account (disconnects banks at Plaid, revokes Apple, deletes all data) |
| `GET /sync/changes?since=N` | ✓ | Everything that changed after version N, oldest first, in pages |
| `POST /sync/push` | ✓ | The app's own edits; newest `updated_at` wins per row |
| `POST /sync/plaid` | ✓ | Fetch new bank data now (used on refresh and during a first import) |
| `POST /link/create`, `POST /link/complete` | ✓ | Plaid Hosted Link; pass `item_id` to reconnect a bank |
| `DELETE /items/:id` | ✓ | Disconnect a bank (stops Plaid billing); its accounts stay as manual ones |
| `POST /plaid/webhook` | Plaid signature | Plaid's updates, verified before use |
| `POST /migrate/claim-legacy` | ✓ owner | One-time move of the old relay's banks into the owner's account |

## How sync works

- Every data row is keyed by `(user_id, id)`, and every query is scoped to the signed-in user.
- Each change gets a per-user `version`. The app asks for changes since the last version it saw and
  pushes its own edits with a client `updated_at`.
- Plaid data (amounts, dates, names, balances) is written only by the server; the app owns
  categories, notes, and everything else. A posted transaction inherits the category of the pending
  one it replaces.
- Webhooks trigger syncs, and a cron every 10 minutes catches anything missed. Each run does a small,
  bounded amount of work because the free plan allows 10 ms of CPU and 50 subrequests per request.

## Restoring the database

D1 Time Travel keeps 7 days of history on the free plan:

```sh
npx wrangler d1 time-travel info budgy-prod
npx wrangler d1 time-travel restore budgy-prod --timestamp=<unix seconds>
```

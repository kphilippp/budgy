# Budgy Relay Server

A tiny Cloudflare Worker that sits between the Budgy iPhone app and Plaid.
It keeps your Plaid secret and bank access tokens off your phone. Free on Cloudflare's free tier.

## One-time setup (about 10 minutes)

1. **Create a Plaid account** at https://dashboard.plaid.com/signup and grab your
   `client_id` and **Sandbox** secret from *Developers → Keys*.
2. **Install Wrangler** (Cloudflare's CLI; requires Node.js):
   ```sh
   cd Server
   npx wrangler login
   ```
3. **Create the storage** for your bank connections:
   ```sh
   npx wrangler kv namespace create ITEMS
   ```
   Paste the printed `id` into `wrangler.toml`.
4. **Add your secrets** (each command prompts for the value):
   ```sh
   npx wrangler secret put PLAID_CLIENT_ID
   npx wrangler secret put PLAID_SECRET
   npx wrangler secret put APP_TOKEN    # make up a long random password, e.g. `openssl rand -hex 32`
   ```
5. **Deploy**:
   ```sh
   npx wrangler deploy
   ```
   Copy the URL it prints (like `https://budgy-relay.<you>.workers.dev`).
6. In Budgy: **Settings → Bank Connections**, paste the server URL and your `APP_TOKEN`,
   then tap **Connect a Bank**.

## Testing with fake data

While `PLAID_ENV = "sandbox"`, connect any bank and log in with
username `user_good`, password `pass_good`. You'll get realistic fake transactions.

## Going live

1. In the Plaid dashboard, request **Production** access (Trial plan is free for up to 10 connections).
2. Replace the `PLAID_SECRET` with your Production secret: `npx wrangler secret put PLAID_SECRET`.
3. Set `PLAID_ENV = "production"` in `wrangler.toml` and run `npx wrangler deploy` again.
4. In the Plaid dashboard, add `budgy://plaid-complete` under *Allowed redirect URIs* if prompted.

## Endpoints

All are `POST` with `Authorization: Bearer <APP_TOKEN>`.

| Path | Purpose |
|---|---|
| `/health` | Connection test |
| `/link/create` | Creates a Hosted Link session (`{kind: "bank" \| "investments"}`) |
| `/link/complete` | Exchanges the finished session for access tokens (stored in KV) |
| `/accounts` | Balances for every connected account |
| `/transactions/sync` | Incremental transaction sync using cursors the app stores |
| `/items/remove` | Disconnects a bank (and stops Plaid billing for it) |

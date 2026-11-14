import { limitAuthAttempts, loadProfile, upsertUser } from "./auth/routes";
import { authenticate, issueSession } from "./auth/session";
import type { Env } from "./env";
import { constantTimeEqual, plaidTokenContext, unseal } from "./lib/crypto";
import { ApiError, json, optionalString, readBody, string } from "./lib/http";
import { plaid } from "./plaid/client";
import { storeNewItem } from "./plaid/link";
import { ITEM_COLUMNS, syncItem, type SyncableItem } from "./plaid/sync";

// Routes that exist only in the dev environment (budgy-dev, Plaid sandbox), for end-to-end tests
// before the app has Sign in with Apple. Production never routes here.

export function devRoutesEnabled(env: Env): boolean {
  return env.ENVIRONMENT === "dev" && env.PLAID_ENV === "sandbox";
}

/** POST /dev/login {secret, name} — a test user without Apple. Needs the dev-only DEV_TEST_LOGIN_SECRET. */
export async function devLogin(request: Request, env: Env): Promise<Response> {
  await limitAuthAttempts(request, env);
  const body = await readBody(request, 4 * 1024);
  const secret = string(body, "secret", { max: 256 });
  if (!env.DEV_TEST_LOGIN_SECRET || !constantTimeEqual(secret, env.DEV_TEST_LOGIN_SECRET)) {
    throw new ApiError(401, "unauthorized", "Wrong dev secret.");
  }
  const name = string(body, "name", { max: 40, pattern: /^[a-z0-9-]+$/ });
  const user = await upsertUser(env, `dev:${name}`, `${name}@dev.budgy.invalid`, name, "America/Chicago");
  return json({ ...(await issueSession(env, user.id)), user: await loadProfile(env, user.id), is_new_user: user.isNew });
}

/** POST /dev/sandbox-item {institution_id?} — links a Plaid sandbox bank without the Link UI. */
export async function devSandboxItem(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const user = await authenticate(request, env);
  const body = await readBody(request, 4 * 1024);
  const institutionId = optionalString(body, "institution_id", { max: 40, pattern: /^ins_\d+$/ }) ?? "ins_109508";
  const { public_token } = await plaid<{ public_token: string }>(env, "/sandbox/public_token/create", {
    institution_id: institutionId,
    initial_products: ["transactions"],
    options: { webhook: `${env.PUBLIC_URL}/plaid/webhook` },
  });
  const item = await storeNewItem(env, user, public_token, { name: `Sandbox ${institutionId}`, institution_id: institutionId }, false);
  ctx.waitUntil(
    (async () => {
      const row = await env.DB.prepare(`SELECT ${ITEM_COLUMNS} FROM plaid_items WHERE user_id = ?1 AND id = ?2`).bind(user.id, item.id).first<SyncableItem>();
      if (row) await syncItem(env, row, { maxPages: 1 });
    })(),
  );
  return json({ item });
}

/** POST /dev/fire-webhook {item_id} — asks Plaid's sandbox to send a real, signed SYNC_UPDATES_AVAILABLE webhook. */
export async function devFireWebhook(request: Request, env: Env): Promise<Response> {
  const user = await authenticate(request, env);
  const body = await readBody(request, 4 * 1024);
  const itemId = string(body, "item_id", { max: 128 });
  const item = await env.DB.prepare("SELECT access_token FROM plaid_items WHERE user_id = ?1 AND id = ?2 AND access_token IS NOT NULL")
    .bind(user.id, itemId)
    .first<{ access_token: string }>();
  if (!item) throw new ApiError(404, "not_found", "No such item.");
  await plaid(env, "/sandbox/item/fire_webhook", {
    access_token: await unseal(env, item.access_token, plaidTokenContext(user.id, itemId)),
    webhook_type: "TRANSACTIONS",
    webhook_code: "SYNC_UPDATES_AVAILABLE",
  });
  return json({ fired: true });
}

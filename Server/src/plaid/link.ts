import type { Env, User } from "../env";
import { plaidTokenContext, seal, unseal } from "../lib/crypto";
import { versionedBatch } from "../lib/db";
import { ApiError, json, noContent, optionalString, readBody, string } from "../lib/http";
import { PlaidError, plaid } from "./client";
import { ITEM_COLUMNS, syncItem, type SyncableItem } from "./sync";

// Bank linking uses Plaid Hosted Link: the app opens hosted_link_url in a secure browser sheet,
// Plaid sends the user back to budgy://plaid-complete, and the app calls /link/complete.

const REDIRECT_URI = "budgy://plaid-complete";
const ITEM_ID = /^[\w-]{1,128}$/;

async function ownedItem(env: Env, user: User, itemId: string): Promise<SyncableItem> {
  const item = await env.DB.prepare(`SELECT ${ITEM_COLUMNS} FROM plaid_items WHERE user_id = ?1 AND id = ?2 AND deleted_at IS NULL`)
    .bind(user.id, itemId)
    .first<SyncableItem>();
  if (!item) throw new ApiError(404, "not_found", "That bank connection doesn't exist.");
  return item;
}

/** POST /link/create {kind: "bank" | "investments", item_id?} — item_id reconnects an existing bank (update mode). */
export async function createLink(request: Request, env: Env, user: User): Promise<Response> {
  const body = await readBody(request, 8 * 1024);
  const kind = optionalString(body, "kind", { pattern: /^(bank|investments)$/ }) ?? "bank";
  const itemId = optionalString(body, "item_id", { pattern: ITEM_ID });

  const payload: Record<string, unknown> = {
    client_name: "Budgy",
    language: "en",
    country_codes: ["US"],
    user: { client_user_id: user.id },
    webhook: `${env.PUBLIC_URL}/plaid/webhook`,
    hosted_link: { completion_redirect_uri: REDIRECT_URI },
  };
  if (itemId) {
    const item = await ownedItem(env, user, itemId);
    if (!item.access_token) throw new ApiError(404, "not_found", "That bank connection doesn't exist.");
    payload.access_token = await unseal(env, item.access_token, plaidTokenContext(user.id, item.id));
  } else if (kind === "investments") {
    payload.products = ["investments"];
  } else {
    payload.products = ["transactions"];
    payload.transactions = { days_requested: 365 };
  }

  const link = await plaid<{ link_token: string; hosted_link_url: string; expiration: string }>(env, "/link/token/create", payload);
  await env.DB.prepare("INSERT INTO link_sessions (link_token, user_id, kind, item_id, created_at) VALUES (?1, ?2, ?3, ?4, ?5)")
    .bind(link.link_token, user.id, kind, itemId ?? null, Date.now())
    .run();
  return json({ link_token: link.link_token, hosted_link_url: link.hosted_link_url, expiration: link.expiration });
}

interface LinkTokenGet {
  link_sessions?: {
    finished_at?: string | null;
    exit?: { error?: unknown } | null;
    results?: { item_add_results?: { public_token: string; institution?: { name?: string; institution_id?: string } | null }[] } | null;
  }[];
}

/** Stores a newly linked item for the user (encrypted token) and returns its public fields. */
export async function storeNewItem(
  env: Env,
  user: User,
  publicToken: string,
  institution: { name?: string; institution_id?: string } | null | undefined,
  isInvestments: boolean,
): Promise<{ id: string; institution_name: string; is_investments: boolean }> {
  const exchange = await plaid<{ access_token: string; item_id: string }>(env, "/item/public_token/exchange", { public_token: publicToken });
  const institutionName = institution?.name ?? "Bank";
  const batch = versionedBatch(env.DB, user.id);
  batch.add(
    `INSERT INTO plaid_items (user_id, id, institution_id, institution_name, is_investments, access_token, needs_sync, created_at, updated_at, version)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, 1, ?7, ?7, {version})
     ON CONFLICT (user_id, id) DO UPDATE SET access_token = excluded.access_token, status = 'active', last_error = '',
       needs_sync = 1, deleted_at = NULL, version = excluded.version`,
    exchange.item_id,
    institution?.institution_id ?? null,
    institutionName,
    isInvestments ? 1 : 0,
    await seal(env, exchange.access_token, plaidTokenContext(user.id, exchange.item_id)),
    Date.now(),
  );
  await batch.run();
  return { id: exchange.item_id, institution_name: institutionName, is_investments: isInvestments };
}

/** POST /link/complete {link_token} — finishes a Hosted Link session the user started. */
export async function completeLink(request: Request, env: Env, user: User, ctx: ExecutionContext): Promise<Response> {
  const body = await readBody(request, 8 * 1024);
  const linkToken = string(body, "link_token", { max: 256 });
  const session = await env.DB.prepare("SELECT kind, item_id, completed_at FROM link_sessions WHERE link_token = ?1 AND user_id = ?2")
    .bind(linkToken, user.id)
    .first<{ kind: string; item_id: string | null; completed_at: number | null }>();
  if (!session) throw new ApiError(404, "not_found", "That bank connection session doesn't exist.");
  if (session.completed_at) return json({ items: [], reconnected: false, finished: true });

  const data = await plaid<LinkTokenGet>(env, "/link/token/get", { link_token: linkToken });
  const sessions = data.link_sessions ?? [];
  const items: { id: string; institution_name: string; is_investments: boolean }[] = [];
  let reconnected = false;

  if (session.item_id) {
    // Update mode: success means the user finished Link without an error.
    reconnected = sessions.some((s) => s.finished_at && !s.exit?.error);
    if (reconnected) {
      const batch = versionedBatch(env.DB, user.id);
      batch.add(
        `UPDATE plaid_items SET status = 'active', last_error = '', consent_expires_at = NULL, needs_sync = 1, version = {version}
         WHERE user_id = ?1 AND id = ?2`,
        session.item_id,
      );
      await batch.run();
    }
  } else {
    for (const linkSession of sessions) {
      for (const result of linkSession.results?.item_add_results ?? []) {
        items.push(await storeNewItem(env, user, result.public_token, result.institution, session.kind === "investments"));
      }
    }
  }

  // Close the session only once Plaid says the user finished, so an early check can simply be retried.
  const finished = sessions.some((s) => s.finished_at);
  if (finished) {
    await env.DB.prepare("UPDATE link_sessions SET completed_at = ?2 WHERE link_token = ?1").bind(linkToken, Date.now()).run();
  }

  // Start the first sync now; the app keeps pulling while the import finishes.
  const toSync = session.item_id ? [session.item_id] : items.map((item) => item.id);
  ctx.waitUntil(
    (async () => {
      for (const id of toSync.slice(0, 2)) {
        const item = await ownedItem(env, user, id);
        await syncItem(env, item, { maxPages: 1 });
      }
    })().catch((error) => console.error(JSON.stringify({ event: "initial_sync_failed", message: String(error?.message ?? error) }))),
  );
  return json({ items, reconnected, finished });
}

/** DELETE /items/:id — disconnects a bank at Plaid (which stops billing) and keeps its history as manual accounts. */
export async function removeItem(env: Env, user: User, itemId: string): Promise<Response> {
  if (!ITEM_ID.test(itemId)) throw new ApiError(404, "not_found", "That bank connection doesn't exist.");
  const item = await ownedItem(env, user, itemId);
  if (item.access_token) {
    try {
      await plaid(env, "/item/remove", { access_token: await unseal(env, item.access_token, plaidTokenContext(user.id, item.id)) });
    } catch (error) {
      if (!(error instanceof PlaidError && error.code === "ITEM_NOT_FOUND")) throw error;
    }
  }
  const { results: accounts } = await env.DB.prepare("SELECT id FROM accounts WHERE user_id = ?1 AND plaid_item_id = ?2")
    .bind(user.id, itemId)
    .all<{ id: string }>();
  const now = Date.now();
  const batch = versionedBatch(env.DB, user.id);
  batch.add(
    `UPDATE plaid_items SET access_token = NULL, deleted_at = ?3, needs_sync = 0, version = {version} WHERE user_id = ?1 AND id = ?2`,
    itemId,
    now,
  );
  for (const account of accounts) {
    batch.add(
      `UPDATE accounts SET plaid_account_id = NULL, plaid_item_id = NULL, updated_at = ?3, version = {version} WHERE user_id = ?1 AND id = ?2`,
      account.id,
      now,
    );
  }
  await batch.run();
  return noContent();
}

import type { Env, User } from "./env";
import { plaidTokenContext, seal } from "./lib/crypto";
import { versionedBatch } from "./lib/db";
import { ApiError, json } from "./lib/http";
import { plaid } from "./plaid/client";

// One-time move of the old single-user relay's bank connections (KV entries "item:<id>" with no
// owner) into D1 under their owner's account, so nothing has to be re-linked (and billed again).
// Only the user named by LEGACY_OWNER_USER_ID may run it, and only once. The KV entries stay
// until they're deleted by hand after everything checks out.

interface LegacyItem {
  access_token: string;
  institution_name?: string;
  is_investments?: boolean;
}

/** POST /migrate/claim-legacy */
export async function claimLegacyItems(env: Env, user: User): Promise<Response> {
  if (!env.LEGACY_ITEMS) throw new ApiError(404, "not_found", "Nothing to claim here.");
  if (!env.LEGACY_OWNER_USER_ID || env.LEGACY_OWNER_USER_ID !== user.id) {
    throw new ApiError(403, "not_owner", "These bank connections belong to a different account.");
  }
  const claimed = await env.DB.prepare("SELECT value FROM meta WHERE key = 'legacy_claim'").first<string>("value");
  if (claimed) throw new ApiError(409, "already_claimed", "Your earlier bank connections were already moved to your account.");

  const legacy: { id: string; item: LegacyItem }[] = [];
  let cursor: string | undefined;
  do {
    const page = await env.LEGACY_ITEMS.list({ prefix: "item:", cursor });
    for (const key of page.keys) {
      const item = await env.LEGACY_ITEMS.get<LegacyItem>(key.name, "json");
      if (item?.access_token) legacy.push({ id: key.name.slice("item:".length), item });
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);

  const now = Date.now();
  const batch = versionedBatch(env.DB, user.id);
  for (const { id, item } of legacy) {
    batch.add(
      `INSERT INTO plaid_items (user_id, id, institution_name, is_investments, access_token, needs_sync, is_legacy, created_at, updated_at, version)
       VALUES (?1, ?2, ?3, ?4, ?5, 1, 1, ?6, ?6, {version})
       ON CONFLICT (user_id, id) DO NOTHING`,
      id,
      item.institution_name ?? "Bank",
      item.is_investments ? 1 : 0,
      await seal(env, item.access_token, plaidTokenContext(user.id, id)),
      now,
    );
  }
  await batch.run();
  await env.DB.prepare("INSERT INTO meta (key, value, updated_at) VALUES ('legacy_claim', ?1, ?2)")
    .bind(JSON.stringify({ user_id: user.id, items: legacy.map((l) => l.id), at: now }), now)
    .run();

  // These items were linked without a webhook; point Plaid's updates at the new server.
  for (const { item } of legacy) {
    try {
      await plaid(env, "/item/webhook/update", { access_token: item.access_token, webhook: `${env.PUBLIC_URL}/plaid/webhook` });
    } catch (error) {
      console.warn(JSON.stringify({ event: "legacy_webhook_update_failed", code: (error as { code?: string })?.code }));
    }
  }

  console.log(JSON.stringify({ event: "legacy_claimed", items: legacy.length }));
  return json({
    items: legacy.map(({ id, item }) => ({ id, institution_name: item.institution_name ?? "Bank", is_investments: !!item.is_investments })),
  });
}

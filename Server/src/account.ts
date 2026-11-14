import { revokeAppleToken } from "./auth/apple";
import { loadProfile } from "./auth/routes";
import { PULL_TABLES } from "./data/tables";
import type { Env, User } from "./env";
import { appleTokenContext, plaidTokenContext, unseal } from "./lib/crypto";
import { ApiError, json, noContent } from "./lib/http";
import { PlaidError, plaid } from "./plaid/client";

/** GET /me */
export async function getMe(env: Env, user: User): Promise<Response> {
  return json({ user: await loadProfile(env, user.id) });
}

/**
 * DELETE /me — the App Store's required in-app account deletion. Disconnects every bank at Plaid
 * (which stops billing), revokes Sign in with Apple, then deletes all of the user's rows. If a bank
 * can't be disconnected, nothing else is deleted, so the user can try again.
 */
export async function deleteMe(env: Env, user: User): Promise<Response> {
  const { results: items } = await env.DB.prepare(
    "SELECT id, institution_name, access_token FROM plaid_items WHERE user_id = ?1 AND access_token IS NOT NULL",
  )
    .bind(user.id)
    .all<{ id: string; institution_name: string; access_token: string }>();

  for (const item of items) {
    try {
      const accessToken = await unseal(env, item.access_token, plaidTokenContext(user.id, item.id));
      await plaid(env, "/item/remove", { access_token: accessToken });
    } catch (error) {
      const alreadyGone = error instanceof PlaidError && (error.code === "ITEM_NOT_FOUND" || error.code === "INVALID_ACCESS_TOKEN");
      if (!alreadyGone) {
        console.error(JSON.stringify({ event: "delete_account_plaid_failed", code: (error as PlaidError)?.code }));
        throw new ApiError(502, "bank_disconnect_failed", `Couldn't disconnect ${item.institution_name}. Nothing was deleted. Please try again.`);
      }
    }
    // Remember the item is gone at Plaid, in case a later step fails and the user retries.
    await env.DB.prepare("UPDATE plaid_items SET access_token = NULL WHERE user_id = ?1 AND id = ?2").bind(user.id, item.id).run();
  }

  const apple = await env.DB.prepare("SELECT apple_refresh_token FROM users WHERE id = ?1").bind(user.id).first<string | null>("apple_refresh_token");
  if (apple) {
    try {
      await revokeAppleToken(env, await unseal(env, apple, appleTokenContext(user.id)));
    } catch (error) {
      console.warn(JSON.stringify({ event: "apple_revoke_error", message: String((error as Error)?.message ?? error) }));
    }
  }

  await env.DB.batch([
    ...PULL_TABLES.map((table) => env.DB.prepare(`DELETE FROM ${table.name} WHERE user_id = ?1`).bind(user.id)),
    env.DB.prepare("DELETE FROM link_sessions WHERE user_id = ?1").bind(user.id),
    env.DB.prepare("DELETE FROM sessions WHERE user_id = ?1").bind(user.id),
    env.DB.prepare("DELETE FROM users WHERE id = ?1").bind(user.id),
  ]);
  console.log(JSON.stringify({ event: "account_deleted", banks: items.length }));
  return noContent();
}

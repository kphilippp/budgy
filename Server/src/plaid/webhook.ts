import { decodeProtectedHeader, importJWK, jwtVerify, type JWK } from "jose";
import type { Env } from "../env";
import { constantTimeEqual, sha256Hex } from "../lib/crypto";
import { versionedBatch } from "../lib/db";
import { ApiError, json } from "../lib/http";
import { plaid } from "./client";
import { ITEM_COLUMNS, syncItem, type SyncableItem } from "./sync";

const MAX_WEBHOOK_BYTES = 64 * 1024;

// Plaid's webhook signing keys by key id, cached per isolate.
const verificationKeys = new Map<string, Awaited<ReturnType<typeof importJWK>>>();

/**
 * Verifies Plaid's `Plaid-Verification` JWT: ES256, signed by a key Plaid vouches for, issued in
 * the last five minutes, and carrying the SHA-256 of this exact body.
 */
export async function verifyPlaidWebhook(env: Env, request: Request, rawBody: string): Promise<boolean> {
  const token = request.headers.get("plaid-verification");
  if (!token) return false;
  let header;
  try {
    header = decodeProtectedHeader(token);
  } catch {
    return false;
  }
  if (header.alg !== "ES256" || typeof header.kid !== "string") return false;

  let key = verificationKeys.get(header.kid);
  if (!key) {
    try {
      const { key: jwk } = await plaid<{ key: JWK & { expired_at?: number | null } }>(env, "/webhook_verification_key/get", {
        key_id: header.kid,
      });
      if (jwk.expired_at) return false;
      key = await importJWK(jwk, "ES256");
      verificationKeys.set(header.kid, key);
    } catch {
      return false;
    }
  }

  try {
    const { payload } = await jwtVerify(token, key, { algorithms: ["ES256"], maxTokenAge: "5 min" });
    const claimed = payload.request_body_sha256;
    return typeof claimed === "string" && constantTimeEqual(claimed, await sha256Hex(rawBody));
  } catch {
    return false;
  }
}

interface PlaidWebhook {
  webhook_type?: string;
  webhook_code?: string;
  item_id?: string;
  error?: { error_code?: string; error_message?: string; display_message?: string | null } | null;
  consent_expiration_time?: string | null;
}

async function setItemState(env: Env, item: SyncableItem, fields: { status?: string; lastError?: string; consentExpiresAt?: number | null; needsSync?: boolean }) {
  const batch = versionedBatch(env.DB, item.user_id);
  batch.add(
    `UPDATE plaid_items SET
       status = COALESCE(?3, status),
       last_error = COALESCE(?4, last_error),
       consent_expires_at = CASE WHEN ?5 = 1 THEN ?6 ELSE consent_expires_at END,
       needs_sync = CASE WHEN ?7 = 1 THEN 1 ELSE needs_sync END,
       version = {version}
     WHERE user_id = ?1 AND id = ?2`,
    item.id,
    fields.status ?? null,
    fields.lastError ?? null,
    fields.consentExpiresAt === undefined ? 0 : 1,
    fields.consentExpiresAt ?? null,
    fields.needsSync ? 1 : 0,
  );
  await batch.run();
}

/** POST /plaid/webhook */
export async function handlePlaidWebhook(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const rawBody = await request.text();
  if (rawBody.length > MAX_WEBHOOK_BYTES) throw new ApiError(413, "body_too_large", "The request is too large.");
  if (!(await verifyPlaidWebhook(env, request, rawBody))) {
    console.warn(JSON.stringify({ event: "plaid_webhook_rejected" }));
    throw new ApiError(401, "invalid_signature", "Webhook signature is invalid.");
  }

  let hook: PlaidWebhook;
  try {
    hook = JSON.parse(rawBody);
  } catch {
    throw new ApiError(400, "invalid_json", "The request body isn't valid JSON.");
  }
  const kind = `${hook.webhook_type ?? ""}:${hook.webhook_code ?? ""}`;
  console.log(JSON.stringify({ event: "plaid_webhook", kind }));

  const item = hook.item_id
    ? await env.DB.prepare(`SELECT ${ITEM_COLUMNS} FROM plaid_items WHERE id = ?1 AND deleted_at IS NULL`)
        .bind(hook.item_id)
        .first<SyncableItem>()
    : null;
  if (!item) return json({ received: true });

  switch (kind) {
    case "TRANSACTIONS:SYNC_UPDATES_AVAILABLE":
    case "TRANSACTIONS:INITIAL_UPDATE":
    case "TRANSACTIONS:HISTORICAL_UPDATE":
    case "TRANSACTIONS:DEFAULT_UPDATE":
    case "HOLDINGS:DEFAULT_UPDATE":
    case "ITEM:NEW_ACCOUNTS_AVAILABLE":
      await setItemState(env, item, { needsSync: true });
      if (item.status !== "login_required" && item.status !== "revoked") {
        ctx.waitUntil(syncItem(env, item, { maxPages: 2 }).catch((error) => console.error(JSON.stringify({ event: "webhook_sync_failed", message: String(error?.message ?? error) }))));
      }
      break;
    case "ITEM:ERROR":
      if (hook.error?.error_code === "ITEM_LOGIN_REQUIRED") {
        await setItemState(env, item, { status: "login_required", lastError: "Your bank needs you to sign in again. Tap Reconnect." });
      } else {
        await setItemState(env, item, { lastError: hook.error?.display_message ?? hook.error?.error_message ?? "Your bank reported a problem." });
      }
      break;
    case "ITEM:LOGIN_REPAIRED":
      await setItemState(env, item, { status: "active", lastError: "", needsSync: true });
      break;
    case "ITEM:PENDING_EXPIRATION": {
      const expires = hook.consent_expiration_time ? Date.parse(hook.consent_expiration_time) : NaN;
      await setItemState(env, item, {
        status: "pending_expiration",
        lastError: "Your bank connection expires soon. Tap Reconnect to keep it.",
        consentExpiresAt: Number.isFinite(expires) ? expires : null,
      });
      break;
    }
    case "ITEM:PENDING_DISCONNECT":
      await setItemState(env, item, { status: "pending_disconnect", lastError: "Your bank connection will stop soon. Tap Reconnect to keep it." });
      break;
    case "ITEM:USER_PERMISSION_REVOKED":
    case "ITEM:USER_ACCOUNT_REVOKED":
      await setItemState(env, item, { status: "revoked", lastError: "Access to this bank was turned off. Connect it again to keep syncing." });
      break;
    default:
      break;
  }
  return json({ received: true });
}

import type { Env } from "../env";
import { plaidTokenContext, unseal } from "../lib/crypto";
import { versionedBatch } from "../lib/db";
import {
  PlaidError,
  accountKind,
  itemErrorMessage,
  plaid,
  type PlaidAccount,
  type PlaidTransaction,
  type TransactionsSyncResponse,
} from "./client";

// Server-side Plaid sync. Webhooks (and a cron safety net) pull new data from Plaid into D1;
// the app only ever talks to Budgy. The free Workers plan allows 10 ms of CPU and 50
// subrequests per invocation, so each run does a bounded amount of work and saves its place.

export interface SyncableItem {
  user_id: string;
  id: string;
  access_token: string | null;
  cursor: string;
  page_cursor: string | null;
  is_investments: number;
  status: string;
  institution_name: string;
}

export const ITEM_COLUMNS = "user_id, id, access_token, cursor, page_cursor, is_investments, status, institution_name";

const PAGE_SIZE = 250;
const STALE_AFTER_MS = 6 * 60 * 60 * 1000;
/** Statuses where calling Plaid is pointless until the user acts. */
const PAUSED_STATUSES = "('login_required', 'revoked')";

export interface SyncResult {
  pages: number;
  done: boolean;
  error?: string;
}

/** Today's date (YYYY-MM-DD) in the user's time zone, for daily balance snapshots. */
export function localDate(zone: string | null | undefined, now = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: zone ?? "UTC",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(now);
}

const UPSERT_ACCOUNT = `
INSERT INTO accounts (user_id, id, plaid_account_id, plaid_item_id, name, institution, kind_raw, balance, mask,
                      credit_limit, last_updated, sort_order, updated_at, version)
VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, COALESCE(?8, 0), ?9, COALESCE(?10, 0), ?11,
        (SELECT COUNT(*) FROM accounts WHERE user_id = ?1 AND deleted_at IS NULL), 0, {version})
ON CONFLICT (user_id, plaid_account_id) WHERE plaid_account_id IS NOT NULL DO UPDATE SET
  plaid_item_id = excluded.plaid_item_id,
  institution = excluded.institution,
  balance = COALESCE(?8, accounts.balance),
  mask = excluded.mask,
  credit_limit = COALESCE(?10, accounts.credit_limit),
  last_updated = excluded.last_updated,
  deleted_at = NULL,
  version = excluded.version`;

const UPSERT_SNAPSHOT = `
INSERT INTO balance_snapshots (user_id, id, account_id, date, balance, updated_at, version)
SELECT ?1, a.id || ':' || ?2, a.id, ?2, ?4, ?5, {version}
FROM accounts a WHERE a.user_id = ?1 AND a.plaid_account_id = ?3
ON CONFLICT (user_id, id) DO UPDATE SET
  balance = excluded.balance, updated_at = excluded.updated_at, deleted_at = NULL, version = excluded.version
WHERE balance_snapshots.balance <> excluded.balance OR balance_snapshots.deleted_at IS NOT NULL`;

// A posted transaction inherits the app's categorization from the pending one it replaces.
const UPSERT_TRANSACTION = `
INSERT INTO transactions (user_id, id, account_id, name, merchant, amount, date, is_pending, plaid_transaction_id,
                          pending_transaction_id, plaid_category, plaid_category_primary,
                          kind_raw, notes, extra_pay_handled, needs_category_review, category_id, recurring_item_id,
                          updated_at, version)
SELECT ?1, ?2, (SELECT id FROM accounts WHERE user_id = ?1 AND plaid_account_id = ?3), ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
       p.kind_raw, COALESCE(p.notes, ''), COALESCE(p.extra_pay_handled, 0), COALESCE(p.needs_category_review, 0),
       p.category_id, p.recurring_item_id, COALESCE(p.updated_at, 0), {version}
FROM (SELECT 1) AS one
LEFT JOIN transactions p ON p.user_id = ?1 AND ?10 IS NOT NULL AND p.plaid_transaction_id = ?10
WHERE true
ON CONFLICT (user_id, plaid_transaction_id) WHERE plaid_transaction_id IS NOT NULL DO UPDATE SET
  account_id = excluded.account_id,
  name = excluded.name,
  merchant = excluded.merchant,
  amount = excluded.amount,
  date = excluded.date,
  is_pending = excluded.is_pending,
  pending_transaction_id = excluded.pending_transaction_id,
  plaid_category = excluded.plaid_category,
  plaid_category_primary = excluded.plaid_category_primary,
  deleted_at = NULL,
  version = excluded.version`;

const REMOVE_TRANSACTION = `
UPDATE transactions SET deleted_at = ?3, version = {version}
WHERE user_id = ?1 AND plaid_transaction_id = ?2 AND deleted_at IS NULL`;

type Batch = ReturnType<typeof versionedBatch>;

function addAccountWrites(batch: Batch, item: SyncableItem, accounts: PlaidAccount[], today: string, now: number) {
  for (const account of accounts) {
    const kind = accountKind(account.type, account.subtype);
    const balance = account.balances.current ?? account.balances.available;
    batch.add(
      UPSERT_ACCOUNT,
      crypto.randomUUID(),
      account.account_id,
      item.id,
      account.name ?? "",
      item.institution_name,
      kind,
      balance,
      account.mask ?? "",
      account.balances.limit,
      now,
    );
    if (balance !== null) {
      batch.add(UPSERT_SNAPSHOT, today, account.account_id, kind === "creditCard" ? -balance : balance, now);
    }
  }
}

function addTransactionWrites(batch: Batch, page: TransactionsSyncResponse, now: number) {
  const upsert = (t: PlaidTransaction) =>
    batch.add(
      UPSERT_TRANSACTION,
      crypto.randomUUID(),
      t.account_id,
      t.name ?? "",
      t.merchant_name ?? "",
      t.amount,
      t.date,
      t.pending ? 1 : 0,
      t.transaction_id,
      t.pending_transaction_id ?? null,
      t.personal_finance_category?.detailed ?? "",
      t.personal_finance_category?.primary ?? "",
    );
  page.added.forEach(upsert);
  page.modified.forEach(upsert);
  for (const removed of page.removed) batch.add(REMOVE_TRANSACTION, removed.transaction_id, now);
}

async function recordItemError(env: Env, item: SyncableItem, error: PlaidError) {
  const status = error.code === "ITEM_LOGIN_REQUIRED" ? "login_required" : null;
  const batch = versionedBatch(env.DB, item.user_id);
  batch.add(
    `UPDATE plaid_items SET last_error = ?3, status = COALESCE(?4, status), needs_sync = 0, version = {version}
     WHERE user_id = ?1 AND id = ?2`,
    item.id,
    itemErrorMessage(error),
    status,
  );
  await batch.run();
}

/**
 * Pulls balances and up to `maxPages` pages of transaction changes for one item. When Plaid has
 * more, the item keeps needs_sync = 1 and its in-progress cursor, and the next run continues.
 */
export async function syncItem(env: Env, item: SyncableItem, { maxPages = 2 } = {}): Promise<SyncResult> {
  if (!item.access_token) return { pages: 0, done: true };
  const owner = await env.DB.prepare("SELECT time_zone FROM users WHERE id = ?1").bind(item.user_id).first<{ time_zone: string | null }>();
  if (!owner) return { pages: 0, done: true }; // the account is being deleted
  const zone = owner.time_zone;
  const accessToken = await unseal(env, item.access_token, plaidTokenContext(item.user_id, item.id));
  const now = Date.now();
  const markDone = `UPDATE plaid_items SET cursor = COALESCE(?3, cursor), page_cursor = NULL, needs_sync = 0, last_error = '',
      status = CASE WHEN status = 'login_required' THEN 'active' ELSE status END, last_synced_at = ?4, version = {version}
    WHERE user_id = ?1 AND id = ?2`;

  try {
    const { accounts } = await plaid<{ accounts: PlaidAccount[] }>(env, "/accounts/get", { access_token: accessToken });
    let batch = versionedBatch(env.DB, item.user_id);
    addAccountWrites(batch, item, accounts, localDate(zone), now);

    if (item.is_investments) {
      batch.add(markDone, item.id, null, now);
      await batch.run();
      return { pages: 0, done: true };
    }

    let cursor = item.page_cursor ?? item.cursor;
    for (let pages = 1; pages <= maxPages; pages++) {
      let page: TransactionsSyncResponse;
      try {
        page = await plaid<TransactionsSyncResponse>(env, "/transactions/sync", {
          access_token: accessToken,
          ...(cursor ? { cursor } : {}),
          count: PAGE_SIZE,
        });
      } catch (error) {
        if (error instanceof PlaidError && error.code === "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION") {
          // Plaid's data changed mid-run. Restart from the run's first cursor; upserts make replays safe.
          batch.add(
            "UPDATE plaid_items SET page_cursor = NULL, needs_sync = 1, version = {version} WHERE user_id = ?1 AND id = ?2",
            item.id,
          );
          await batch.run();
          return { pages: pages - 1, done: false };
        }
        throw error;
      }

      addTransactionWrites(batch, page, now);
      if (!page.has_more) {
        batch.add(markDone, item.id, page.next_cursor, now);
        await batch.run();
        return { pages, done: true };
      }
      batch.add(
        `UPDATE plaid_items SET page_cursor = ?3, needs_sync = 1, last_error = '', last_synced_at = ?4, version = {version}
         WHERE user_id = ?1 AND id = ?2`,
        item.id,
        page.next_cursor,
        now,
      );
      await batch.run();
      cursor = page.next_cursor;
      batch = versionedBatch(env.DB, item.user_id);
    }
    return { pages: maxPages, done: false };
  } catch (error) {
    if (!(error instanceof PlaidError)) throw error;
    console.warn(JSON.stringify({ event: "plaid_sync_error", code: error.code }));
    await recordItemError(env, item, error);
    return { pages: 0, done: true, error: error.code };
  }
}

/** Cron safety net: syncs items with pending changes first, then any not synced in six hours. */
export async function runScheduledSync(env: Env, budget = 3): Promise<number> {
  const { results } = await env.DB.prepare(
    `SELECT ${ITEM_COLUMNS} FROM plaid_items
     WHERE deleted_at IS NULL AND access_token IS NOT NULL AND status NOT IN ${PAUSED_STATUSES}
       AND (needs_sync = 1 OR last_synced_at IS NULL OR last_synced_at < ?1)
     ORDER BY needs_sync DESC, COALESCE(last_synced_at, 0) ASC
     LIMIT 4`,
  )
    .bind(Date.now() - STALE_AFTER_MS)
    .all<SyncableItem>();
  let synced = 0;
  for (const item of results) {
    if (budget <= 0) break;
    const result = await syncItem(env, item, { maxPages: Math.min(budget, 2) });
    budget -= Math.max(result.pages, 1);
    synced += 1;
  }
  return synced;
}

/**
 * Syncs one user's items that have pending changes or haven't synced in `freshForMs`. Used when
 * the app refreshes, so a first import finishes while the app is open instead of waiting for cron.
 */
export async function syncUserItems(env: Env, userId: string, freshForMs = 15 * 60 * 1000): Promise<{ pending: boolean }> {
  const { results } = await env.DB.prepare(
    `SELECT ${ITEM_COLUMNS} FROM plaid_items
     WHERE user_id = ?1 AND deleted_at IS NULL AND access_token IS NOT NULL AND status NOT IN ${PAUSED_STATUSES}
       AND (needs_sync = 1 OR last_synced_at IS NULL OR last_synced_at < ?2)
     ORDER BY needs_sync DESC, COALESCE(last_synced_at, 0) ASC
     LIMIT 3`,
  )
    .bind(userId, Date.now() - freshForMs)
    .all<SyncableItem>();
  let budget = 2;
  let pending = false;
  for (const item of results) {
    if (budget <= 0) {
      pending = true;
      break;
    }
    const result = await syncItem(env, item, { maxPages: Math.min(budget, 2) });
    budget -= Math.max(result.pages, 1);
    if (!result.done) pending = true;
  }
  return { pending };
}

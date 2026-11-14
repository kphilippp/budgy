import { createExecutionContext, createScheduledController, waitOnExecutionContext } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../src/env";
import worker from "../src/index";
import { appleTokenContext, seal } from "../src/lib/crypto";
import {
  call,
  callJson,
  createUser,
  mockFetch,
  plaidAccount,
  plaidError,
  plaidTransaction,
  seedItem,
  signedWebhook,
  testEnv,
} from "./helpers";

afterEach(() => vi.restoreAllMocks());

type TestUser = Awaited<ReturnType<typeof createUser>>;
const refreshBanks = (user: TestUser) => callJson("/sync/plaid", { token: user.token, body: {} });
const pullAll = async (user: TestUser) => (await callJson("/sync/changes?since=0", { token: user.token })).body.changes;
const item = (id: string) => testEnv.DB.prepare("SELECT * FROM plaid_items WHERE id = ?1").bind(id).first<Record<string, any>>();

describe("server-side Plaid sync", () => {
  it("imports accounts, balances, and transactions across pages", async () => {
    const user = await createUser();
    await seedItem(user.id, "item-1");
    mockFetch({
      "/accounts/get": () => ({
        accounts: [plaidAccount("pa-check"), plaidAccount("pa-card", { type: "credit", subtype: "credit card", current: 300, limit: 2000 })],
      }),
      "/transactions/sync": (body) =>
        body.cursor === "c1"
          ? { added: [plaidTransaction("t3", "pa-check")], modified: [], removed: [], next_cursor: "c2", has_more: false }
          : { added: [plaidTransaction("t1", "pa-check"), plaidTransaction("t2", "pa-card")], modified: [], removed: [], next_cursor: "c1", has_more: true },
    });

    expect((await refreshBanks(user)).body).toEqual({ pending: false });

    const changes = await pullAll(user);
    const card = changes.accounts.find((a: any) => a.plaid_account_id === "pa-card");
    expect(card).toMatchObject({ kind_raw: "creditCard", balance: 300, credit_limit: 2000, institution: "Test Bank" });
    expect(changes.transactions).toHaveLength(3);
    expect(changes.transactions.find((t: any) => t.plaid_transaction_id === "t2")).toMatchObject({
      account_id: card.id,
      kind_raw: null,
      merchant: "Coffee Shop",
      plaid_category: "FOOD_AND_DRINK_COFFEE",
    });
    expect(changes.balance_snapshots.find((s: any) => s.account_id === card.id).balance).toBe(-300);
    expect(changes.plaid_items).toEqual([expect.objectContaining({ id: "item-1", status: "active", last_error: "" })]);
    expect(changes.plaid_items[0]).not.toHaveProperty("access_token");
    expect(await item("item-1")).toMatchObject({ cursor: "c2", page_cursor: null, needs_sync: 0 });
  });

  it("carries the app's categorization from a pending transaction to the posted one", async () => {
    const user = await createUser();
    await seedItem(user.id, "item-1");
    let round = 0;
    mockFetch({
      "/accounts/get": () => ({ accounts: [plaidAccount("pa-check")] }),
      "/transactions/sync": () =>
        round++ === 0
          ? { added: [plaidTransaction("pending-1", "pa-check", { pending: true })], modified: [], removed: [], next_cursor: "c1", has_more: false }
          : { added: [plaidTransaction("posted-1", "pa-check", { pending_transaction_id: "pending-1" })], modified: [], removed: [{ transaction_id: "pending-1" }], next_cursor: "c2", has_more: false },
    });
    await refreshBanks(user);
    const pending = (await pullAll(user)).transactions[0];
    await callJson("/sync/push", { token: user.token, body: { changes: { transactions: [{ ...pending, kind_raw: "expense", category_id: "cat-coffee", updated_at: 50 }] } } });

    await testEnv.DB.prepare("UPDATE plaid_items SET needs_sync = 1").run();
    await refreshBanks(user);
    const transactions = (await pullAll(user)).transactions;
    expect(transactions.find((t: any) => t.plaid_transaction_id === "posted-1")).toMatchObject({ kind_raw: "expense", category_id: "cat-coffee", deleted_at: null });
    expect(transactions.find((t: any) => t.plaid_transaction_id === "pending-1").deleted_at).toEqual(expect.any(Number));
  });

  it("marks an item that needs the user to sign in again, and stops calling Plaid for it", async () => {
    const user = await createUser();
    await seedItem(user.id, "item-1");
    const calls = mockFetch({ "/accounts/get": () => plaidError("ITEM_LOGIN_REQUIRED") });
    await refreshBanks(user);
    expect(await item("item-1")).toMatchObject({ status: "login_required", needs_sync: 0 });
    expect((await pullAll(user)).plaid_items[0].last_error).toMatch(/sign in again/);

    const before = calls.length;
    const ctx = createExecutionContext();
    await worker.scheduled(createScheduledController(), testEnv, ctx);
    await waitOnExecutionContext(ctx);
    expect(calls.length).toBe(before);
  });

  it("doesn't sync for an account that's being deleted, and sweeps up ownerless rows daily", async () => {
    const user = await createUser();
    await seedItem(user.id, "item-1");
    await testEnv.DB.prepare("DELETE FROM users WHERE id = ?1").bind(user.id).run();
    await testEnv.DB.prepare("INSERT INTO goals (user_id, id, name, updated_at, version) VALUES (?1, 'orphan', 'x', 0, 0)").bind(user.id).run();
    const calls = mockFetch();

    const run = async (iso: string) => {
      const ctx = createExecutionContext();
      await worker.scheduled(createScheduledController({ scheduledTime: Date.parse(iso) }), testEnv, ctx);
      await waitOnExecutionContext(ctx);
    };
    await run("2026-11-14T15:00:00Z");
    expect(calls.filter((c) => c.url.includes("plaid.com"))).toEqual([]);
    expect(await testEnv.DB.prepare("SELECT COUNT(*) AS n FROM goals").first<number>("n")).toBe(1);

    await run("2026-11-14T09:00:00Z");
    for (const table of ["goals", "plaid_items"]) {
      expect(await testEnv.DB.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first<number>("n"), table).toBe(0);
    }
  });

  it("cron syncs items that are due", async () => {
    const user = await createUser();
    await seedItem(user.id, "item-1");
    const calls = mockFetch({
      "/accounts/get": () => ({ accounts: [plaidAccount("pa-check")] }),
      "/transactions/sync": () => ({ added: [], modified: [], removed: [], next_cursor: "c1", has_more: false }),
    });
    const ctx = createExecutionContext();
    await worker.scheduled(createScheduledController(), testEnv, ctx);
    await waitOnExecutionContext(ctx);
    expect(calls.map((c) => new URL(c.url).pathname)).toEqual(["/accounts/get", "/transactions/sync"]);
    expect(await item("item-1")).toMatchObject({ needs_sync: 0, cursor: "c1" });
  });
});

describe("Plaid webhooks", () => {
  const hook = { webhook_type: "TRANSACTIONS", webhook_code: "SYNC_UPDATES_AVAILABLE", item_id: "item-1" };
  const send = (signed: { body: string; headers: Record<string, string> }) => call("/plaid/webhook", { body: signed.body, headers: signed.headers });

  it("accepts a correctly signed webhook and syncs the item", async () => {
    const user = await createUser();
    await seedItem(user.id, "item-1");
    await testEnv.DB.prepare("UPDATE plaid_items SET needs_sync = 0").run();
    const calls = mockFetch({
      "/accounts/get": () => ({ accounts: [plaidAccount("pa-check")] }),
      "/transactions/sync": () => ({ added: [plaidTransaction("t1", "pa-check")], modified: [], removed: [], next_cursor: "c1", has_more: false }),
    });
    const response = await send(await signedWebhook(hook));
    expect(response.status).toBe(200);
    expect(calls.some((c) => c.url.endsWith("/transactions/sync"))).toBe(true);
    expect((await pullAll(user)).transactions).toHaveLength(1);
  });

  it("rejects an altered body, an old signature, and a missing signature", async () => {
    const user = await createUser();
    await seedItem(user.id, "item-1");
    const calls = mockFetch();
    expect((await send(await signedWebhook(hook, { tamper: true }))).status).toBe(401);
    expect((await send(await signedWebhook(hook, { issuedAt: Math.floor(Date.now() / 1000) - 600 }))).status).toBe(401);
    expect((await call("/plaid/webhook", { body: JSON.stringify(hook) })).status).toBe(401);
    expect(calls.some((c) => c.url.endsWith("/transactions/sync"))).toBe(false);
  });

  it("records login-required and expiring connections so the app can offer Reconnect", async () => {
    const user = await createUser();
    await seedItem(user.id, "item-1");
    mockFetch();
    await send(await signedWebhook({ webhook_type: "ITEM", webhook_code: "ERROR", item_id: "item-1", error: { error_code: "ITEM_LOGIN_REQUIRED" } }));
    expect(await item("item-1")).toMatchObject({ status: "login_required" });

    await send(await signedWebhook({ webhook_type: "ITEM", webhook_code: "PENDING_EXPIRATION", item_id: "item-1", consent_expiration_time: "2026-12-31T00:00:00Z" }));
    expect(await item("item-1")).toMatchObject({ status: "pending_expiration", consent_expires_at: Date.parse("2026-12-31T00:00:00Z") });
  });
});

describe("linking banks", () => {
  it("creates a Hosted Link session for the user and stores the new bank's token encrypted", async () => {
    const user = await createUser();
    const calls = mockFetch({
      "/link/token/create": () => ({ link_token: "link-1", hosted_link_url: "https://hosted.plaid.test/1", expiration: "2026-11-14T00:00:00Z" }),
      "/link/token/get": () => ({
        link_sessions: [{ finished_at: "2026-11-13T00:00:00Z", results: { item_add_results: [{ public_token: "public-1", institution: { name: "Chase", institution_id: "ins_3" } }] } }],
      }),
      "/item/public_token/exchange": () => ({ access_token: "access-production-SECRET", item_id: "item-new" }),
      "/accounts/get": () => ({ accounts: [] }),
      "/transactions/sync": () => ({ added: [], modified: [], removed: [], next_cursor: "c1", has_more: false }),
    });

    const created = await callJson("/link/create", { token: user.token, body: { kind: "bank" } });
    expect(created.body).toMatchObject({ link_token: "link-1", hosted_link_url: "https://hosted.plaid.test/1" });
    const linkRequest = calls.find((c) => c.url.endsWith("/link/token/create"))!;
    expect(linkRequest.body).toMatchObject({
      user: { client_user_id: user.id },
      products: ["transactions"],
      webhook: "https://budgy.thebudgyapp.workers.dev/plaid/webhook",
      hosted_link: { completion_redirect_uri: "budgy://plaid-complete" },
    });
    expect(linkRequest.headers.get("PLAID-SECRET")).toBe("test-secret");
    expect(JSON.stringify(linkRequest.body)).not.toContain("test-secret");

    const completed = await callJson("/link/complete", { token: user.token, body: { link_token: "link-1" } });
    expect(completed.body.items).toEqual([{ id: "item-new", institution_name: "Chase", is_investments: false }]);
    const stored = await item("item-new");
    expect(stored!.access_token).toMatch(/^v1\./);
    expect(stored!.access_token).not.toContain("SECRET");
  });

  it("disconnects a bank at Plaid and keeps its accounts as manual ones", async () => {
    const user = await createUser();
    await seedItem(user.id, "item-1");
    await testEnv.DB.prepare(
      "INSERT INTO accounts (user_id, id, name, plaid_account_id, plaid_item_id, updated_at, version) VALUES (?1, 'acct-1', 'Checking', 'pa-1', 'item-1', 0, 0)",
    )
      .bind(user.id)
      .run();
    const calls = mockFetch({ "/item/remove": () => ({ removed: true }) });
    expect((await call("/items/item-1", { method: "DELETE", token: user.token })).status).toBe(204);
    expect(calls.find((c) => c.url.endsWith("/item/remove"))!.body).toEqual({ access_token: "access-test-item-1" });
    const changes = await pullAll(user);
    expect(changes.plaid_items[0].deleted_at).toEqual(expect.any(Number));
    expect(changes.accounts[0]).toMatchObject({ id: "acct-1", plaid_account_id: null, deleted_at: null });
  });
});

describe("account deletion", () => {
  it("disconnects every bank, revokes Sign in with Apple, and deletes all of the user's data", async () => {
    const user = await createUser("leaving");
    const stays = await createUser("stays");
    await seedItem(user.id, "item-1");
    await seedItem(stays.id, "item-2");
    await testEnv.DB.prepare("UPDATE users SET apple_refresh_token = ?2 WHERE id = ?1")
      .bind(user.id, await seal(testEnv, "apple-refresh-1", appleTokenContext(user.id)))
      .run();
    await callJson("/sync/push", { token: user.token, body: { changes: { goals: [{ id: "g1", updated_at: 1, name: "Mine" }] } } });
    await callJson("/sync/push", { token: stays.token, body: { changes: { goals: [{ id: "g2", updated_at: 1, name: "Theirs" }] } } });
    const calls = mockFetch({ "/item/remove": () => ({}), "https://appleid.apple.com/auth/revoke": () => new Response(null, { status: 200 }) });

    expect((await call("/me", { method: "DELETE", token: user.token })).status).toBe(204);

    expect(calls.filter((c) => c.url.endsWith("/item/remove")).map((c) => c.body.access_token)).toEqual(["access-test-item-1"]);
    expect(calls.find((c) => c.url.endsWith("/auth/revoke"))!.body).toMatchObject({ token: "apple-refresh-1", token_type_hint: "refresh_token" });
    for (const table of ["users", "sessions", "plaid_items", "goals"]) {
      const column = table === "users" ? "id" : "user_id";
      const count = await testEnv.DB.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE ${column} = ?1`).bind(user.id).first<number>("n");
      expect(count, table).toBe(0);
    }
    expect((await callJson("/me", { token: user.token })).status).toBe(401);
    expect((await pullAll(stays)).goals).toHaveLength(1);
  });

  it("deletes nothing if a bank can't be disconnected", async () => {
    const user = await createUser();
    await seedItem(user.id, "item-1");
    mockFetch({ "/item/remove": () => plaidError("INTERNAL_SERVER_ERROR", 500) });
    const response = await callJson("/me", { method: "DELETE", token: user.token });
    expect(response.status).toBe(502);
    expect(response.body.error.message).toMatch(/Nothing was deleted/);
    expect((await callJson("/me", { token: user.token })).status).toBe(200);
  });
});

describe("legacy relay claim", () => {
  it("moves the old relay's banks to the owner, once", async () => {
    await testEnv.LEGACY_ITEMS!.put("item:legacy-1", JSON.stringify({ access_token: "access-legacy-1", institution_name: "Chase", is_investments: false }));
    const owner = await createUser("owner");
    const other = await createUser("other");
    const asOwner: Partial<Env> = { LEGACY_OWNER_USER_ID: owner.id };
    const calls = mockFetch({ "/item/webhook/update": () => ({}) });

    expect((await callJson("/migrate/claim-legacy", { token: other.token, body: {} }, asOwner)).status).toBe(403);

    const claimed = await callJson("/migrate/claim-legacy", { token: owner.token, body: {} }, asOwner);
    expect(claimed.status).toBe(200);
    expect(claimed.body.items).toEqual([{ id: "legacy-1", institution_name: "Chase", is_investments: false }]);
    const stored = await item("legacy-1");
    expect(stored).toMatchObject({ user_id: owner.id, is_legacy: 1, needs_sync: 1 });
    expect(stored!.access_token).not.toContain("access-legacy-1");
    expect(calls.find((c) => c.url.endsWith("/item/webhook/update"))!.body).toEqual({
      access_token: "access-legacy-1",
      webhook: "https://budgy.thebudgyapp.workers.dev/plaid/webhook",
    });

    expect((await callJson("/migrate/claim-legacy", { token: owner.token, body: {} }, asOwner)).status).toBe(409);
    expect(await testEnv.LEGACY_ITEMS!.get("item:legacy-1")).not.toBeNull();
  });

  it("refuses when no owner is configured", async () => {
    const user = await createUser();
    expect((await callJson("/migrate/claim-legacy", { token: user.token, body: {} })).status).toBe(403);
  });
});

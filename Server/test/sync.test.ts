import { afterEach, describe, expect, it, vi } from "vitest";
import { callJson, createUser, mockFetch, seedItem, testEnv } from "./helpers";

afterEach(() => vi.restoreAllMocks());

type TestUser = Awaited<ReturnType<typeof createUser>>;
const push = (user: TestUser, changes: Record<string, unknown[]>) => callJson("/sync/push", { token: user.token, body: { changes } });
const pull = (user: TestUser, since = 0, limit?: number) =>
  callJson(`/sync/changes?since=${since}${limit ? `&limit=${limit}` : ""}`, { token: user.token });

describe("sync push and pull", () => {
  it("round-trips rows, including deletions", async () => {
    const user = await createUser();
    const pushed = await push(user, {
      goals: [{ id: "goal-1", updated_at: 1000, name: "Trip", target_amount: 500, is_archived: false }],
      categories: [{ id: "cat-1", updated_at: 1000, name: "Food" }],
    });
    expect(pushed.body).toMatchObject({ applied: 2, skipped: 0, remapped: [] });

    const first = await pull(user);
    expect(first.body.changes.goals).toEqual([
      expect.objectContaining({ id: "goal-1", name: "Trip", target_amount: 500, is_archived: false, deleted_at: null, color_name: "purple" }),
    ]);
    expect(first.body.changes.categories).toHaveLength(1);

    await push(user, { goals: [{ id: "goal-1", updated_at: 2000, deleted: true, name: "Trip" }] });
    const second = await pull(user, first.body.next);
    expect(second.body.changes.goals).toEqual([expect.objectContaining({ id: "goal-1", deleted_at: 2000 })]);
    expect(second.body.changes.categories).toEqual([]);
  });

  it("keeps the newest edit when an older one arrives later", async () => {
    const user = await createUser();
    await push(user, { goals: [{ id: "goal-1", updated_at: 2000, name: "Newer" }] });
    const stale = await push(user, { goals: [{ id: "goal-1", updated_at: 1000, name: "Older" }] });
    expect(stale.body).toMatchObject({ applied: 0, skipped: 1 });
    expect((await pull(user)).body.changes.goals[0].name).toBe("Newer");
  });

  it("pages through changes in order without skipping any", async () => {
    const user = await createUser();
    await push(user, { goals: [1, 2, 3].map((n) => ({ id: `goal-${n}`, updated_at: n, name: `Goal ${n}` })) });
    await push(user, { categories: [4, 5].map((n) => ({ id: `cat-${n}`, updated_at: n, name: `Cat ${n}` })) });
    const seen: string[] = [];
    let since = 0;
    for (let page = 0; page < 10; page++) {
      const { body } = await pull(user, since, 2);
      for (const rows of Object.values(body.changes) as { id: string }[][]) seen.push(...rows.map((r) => r.id));
      since = body.next;
      if (!body.has_more) break;
    }
    expect(seen.sort()).toEqual(["cat-4", "cat-5", "goal-1", "goal-2", "goal-3"]);
  });

  it("rejects malformed pushes", async () => {
    const user = await createUser();
    expect((await push(user, { goals: [{ id: "g", updated_at: 1, target_amount: "lots" }] })).status).toBe(400);
    expect((await push(user, { goals: [{ id: "g" }] })).status).toBe(400);
    expect((await push(user, { secrets: [] })).status).toBe(400);
    const tooMany = Array.from({ length: 501 }, (_, n) => ({ id: `g${n}`, updated_at: 1 }));
    expect((await push(user, { goals: tooMany })).status).toBe(413);
  });

  it("lets the app categorize Plaid transactions but not change what the bank reported", async () => {
    const user = await createUser();
    await testEnv.DB.prepare(
      `INSERT INTO transactions (user_id, id, name, amount, date, plaid_transaction_id, updated_at, version) VALUES (?1, 'txn-1', 'COFFEE', 4.5, '2026-11-01', 'plaid-txn-1', 0, 0)`,
    )
      .bind(user.id)
      .run();
    await push(user, { transactions: [{ id: "txn-1", updated_at: 5000, amount: 999, name: "Edited", kind_raw: "expense", category_id: "cat-food" }] });
    const row = await testEnv.DB.prepare("SELECT amount, name, kind_raw, category_id FROM transactions WHERE id = 'txn-1'").first();
    expect(row).toEqual({ amount: 4.5, name: "COFFEE", kind_raw: "expense", category_id: "cat-food" });
  });

  it("matches uploaded accounts and transactions to ones the server already has", async () => {
    const user = await createUser();
    await testEnv.DB.prepare(
      `INSERT INTO accounts (user_id, id, name, plaid_account_id, updated_at, version) VALUES (?1, 'server-account', 'Checking', 'plaid-acct-1', 0, 0)`,
    )
      .bind(user.id)
      .run();
    const pushed = await push(user, {
      accounts: [{ id: "local-account", updated_at: 10, name: "My checking", plaid_account_id: "plaid-acct-1" }],
      balance_snapshots: [{ id: "local-account:2026-11-01", updated_at: 10, account_id: "local-account", date: "2026-11-01", balance: 100 }],
      transactions: [{ id: "local-txn", updated_at: 10, account_id: "local-account", plaid_transaction_id: "plaid-txn-9", amount: 3, date: "2026-11-01" }],
    });
    expect(pushed.status).toBe(200);
    expect(pushed.body.remapped).toEqual([{ table: "accounts", from: "local-account", to: "server-account" }]);
    const account = await testEnv.DB.prepare("SELECT id, name FROM accounts WHERE user_id = ?1").bind(user.id).all();
    expect(account.results).toEqual([{ id: "server-account", name: "My checking" }]);
    const txn = await testEnv.DB.prepare("SELECT account_id FROM transactions WHERE id = 'local-txn'").first<string>("account_id");
    expect(txn).toBe("server-account");
    const snapshot = await testEnv.DB.prepare("SELECT id FROM balance_snapshots WHERE user_id = ?1").bind(user.id).first<string>("id");
    expect(snapshot).toBe("server-account:2026-11-01");
  });
});

describe("isolation between users", () => {
  it("never shows or changes one user's rows for another", async () => {
    const alice = await createUser("alice");
    const bob = await createUser("bob");
    await push(alice, { goals: [{ id: "shared-id", updated_at: 1000, name: "Alice's goal", target_amount: 100 }] });

    expect((await pull(bob)).body.changes.goals).toEqual([]);

    // Bob writing the same id (even newer, even a delete) only ever touches Bob's own row.
    await push(bob, { goals: [{ id: "shared-id", updated_at: 9000, name: "Bob's goal", deleted: true }] });
    const aliceGoals = (await pull(alice)).body.changes.goals;
    expect(aliceGoals).toEqual([expect.objectContaining({ id: "shared-id", name: "Alice's goal", deleted_at: null })]);
    expect((await pull(bob)).body.changes.goals).toEqual([expect.objectContaining({ name: "Bob's goal" })]);
  });

  it("won't let one user reconnect, remove, or finish linking another user's bank", async () => {
    const alice = await createUser("alice");
    const bob = await createUser("bob");
    await seedItem(alice.id, "alice-item");
    await testEnv.DB.prepare("INSERT INTO link_sessions (link_token, user_id, kind, created_at) VALUES ('alice-link', ?1, 'bank', 0)").bind(alice.id).run();
    const calls = mockFetch();

    expect((await callJson("/items/alice-item", { method: "DELETE", token: bob.token })).status).toBe(404);
    expect((await callJson("/link/create", { token: bob.token, body: { item_id: "alice-item" } })).status).toBe(404);
    expect((await callJson("/link/complete", { token: bob.token, body: { link_token: "alice-link" } })).status).toBe(404);
    expect(calls.filter((c) => c.url.includes("plaid.com"))).toEqual([]);

    const item = await testEnv.DB.prepare("SELECT deleted_at FROM plaid_items WHERE id = 'alice-item'").first();
    expect(item).toEqual({ deleted_at: null });
  });
});

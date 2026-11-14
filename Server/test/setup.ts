import { applyD1Migrations, env, type D1Migration } from "cloudflare:test";

import { beforeEach } from "vitest";

// Apply the real migrations to the test database, and start every test from empty tables.
const bindings = env as unknown as { DB: D1Database; TEST_MIGRATIONS: D1Migration[]; LEGACY_ITEMS: KVNamespace };
await applyD1Migrations(bindings.DB, bindings.TEST_MIGRATIONS);

const tables = [
  "users", "sessions", "link_sessions", "plaid_items", "accounts", "balance_snapshots", "categories",
  "transactions", "recurring_items", "goals", "pay_schedules", "merchant_rules", "meta",
];

beforeEach(async () => {
  await bindings.DB.batch(tables.map((table) => bindings.DB.prepare(`DELETE FROM ${table}`)));
  const { keys } = await bindings.LEGACY_ITEMS.list();
  await Promise.all(keys.map((key) => bindings.LEGACY_ITEMS.delete(key.name)));
});

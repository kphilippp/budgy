// End-to-end check of budgy-dev against Plaid's sandbox. Prints counts and statuses only.
//
//   npm run e2e:dev                      full run, then deletes the test users (and their sandbox banks)
//   npm run e2e:dev -- --link-start      signs in "e2e-link" and prints a Plaid Hosted Link URL to open
//   npm run e2e:dev -- --link-finish     after logging in there (user_good / pass_good): completes the
//                                        link, checks the imported data, then deletes the test user
//
// Reads DEV_TEST_LOGIN_SECRET from Server/.dev.vars; keeps link-test state in Server/.e2e-state.json
// (both git-ignored).
import { readFileSync, rmSync, writeFileSync } from "node:fs";

const BASE = process.env.BUDGY_DEV_URL ?? "https://budgy-dev.thebudgyapp.workers.dev";
const STATE = new URL("../.e2e-state.json", import.meta.url);
const secret = /DEV_TEST_LOGIN_SECRET=(.+)/.exec(readFileSync(new URL("../.dev.vars", import.meta.url), "utf8"))?.[1]?.trim();
if (!secret) throw new Error("DEV_TEST_LOGIN_SECRET missing from Server/.dev.vars");

let failures = 0;
const check = (label, ok, detail = "") => {
  console.log(`${ok ? "✓" : "✗"} ${label}${detail ? ` — ${detail}` : ""}`);
  if (!ok) failures++;
};
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function api(path, { method, token, body } = {}) {
  const response = await fetch(`${BASE}${path}`, {
    method: method ?? (body ? "POST" : "GET"),
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body ? { "content-type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null };
}

async function pullAll(token) {
  const all = {};
  let since = 0;
  for (;;) {
    const { body } = await api(`/sync/changes?since=${since}`, { token });
    for (const [table, rows] of Object.entries(body.changes)) (all[table] ??= []).push(...rows);
    since = body.next;
    if (!body.has_more) return all;
  }
}

if (process.argv.includes("--link-start")) {
  const user = (await api("/dev/login", { body: { secret, name: "e2e-link" } })).body;
  const link = await api("/link/create", { token: user.access_token, body: { kind: "bank" } });
  check("hosted link created", link.status === 200, link.body?.error?.message ?? "");
  writeFileSync(STATE, JSON.stringify({ refresh_token: user.refresh_token, link_token: link.body.link_token }), { mode: 0o600 });
  console.log(`\nOpen this sandbox link and sign in with user_good / pass_good:\n${link.body.hosted_link_url}`);
  process.exit(failures ? 1 : 0);
}

if (process.argv.includes("--link-finish")) {
  const state = JSON.parse(readFileSync(STATE, "utf8"));
  const session = (await api("/auth/refresh", { body: { refresh_token: state.refresh_token } })).body;
  const completed = await api("/link/complete", { token: session.access_token, body: { link_token: state.link_token } });
  check("link completed", completed.status === 200 && completed.body.finished, JSON.stringify(completed.body));
  let data = {};
  const started = Date.now();
  while (Date.now() - started < 90_000) {
    await api("/sync/plaid", { token: session.access_token, body: {} });
    data = await pullAll(session.access_token);
    if ((data.transactions ?? []).length > 0) break;
    await sleep(5000);
  }
  check("bank from Hosted Link imported", (data.transactions ?? []).length > 0, `${data.accounts?.length ?? 0} accounts, ${data.transactions?.length ?? 0} transactions, item ${data.plaid_items?.[0]?.institution_name}`);
  const removed = await api("/me", { method: "DELETE", token: session.access_token });
  check("test user and sandbox bank deleted", removed.status === 204);
  rmSync(STATE, { force: true });
  console.log(failures ? `\n${failures} check(s) failed` : "\nHosted Link check passed");
  process.exit(failures ? 1 : 0);
}

const health = await api("/health");
check("health", health.status === 200 && health.body.ok && health.body.env === "dev", `${health.body.env}, plaid ${health.body.plaid_env}`);

const alice = (await api("/dev/login", { body: { secret, name: "e2e-alice" } })).body;
const bob = (await api("/dev/login", { body: { secret, name: "e2e-bob" } })).body;
check("dev sign-in for two users", Boolean(alice.access_token && bob.access_token && alice.user.id !== bob.user.id));

const linked = await api("/dev/sandbox-item", { token: alice.access_token, body: { institution_id: "ins_109508" } });
check("sandbox bank linked (public token → encrypted access token)", linked.status === 200, linked.body?.item?.institution_name);
const itemId = linked.body?.item?.id;

// Plaid prepares sandbox history in the background, then sends a signed SYNC_UPDATES_AVAILABLE webhook.
let data = {};
const started = Date.now();
while (Date.now() - started < 90_000) {
  await api("/sync/plaid", { token: alice.access_token, body: {} });
  data = await pullAll(alice.access_token);
  if ((data.transactions ?? []).length > 0 && !(data.plaid_items ?? []).some((i) => i.status !== "active")) break;
  await sleep(5000);
}
const live = (rows) => (rows ?? []).filter((r) => !r.deleted_at);
check("accounts imported", live(data.accounts).length > 0, `${live(data.accounts).length} accounts`);
check("transactions imported", live(data.transactions).length > 0, `${live(data.transactions).length} transactions after ${Math.round((Date.now() - started) / 1000)}s`);
check("balance snapshots recorded", live(data.balance_snapshots).length > 0, `${live(data.balance_snapshots).length} snapshots`);
check("item status visible to the app", data.plaid_items?.[0]?.status === "active", JSON.stringify(data.plaid_items?.map((i) => i.status)));
check("transactions arrive uncategorized for the app", live(data.transactions).every((t) => t.kind_raw === null));

const txn = live(data.transactions)[0];
const pushed = await api("/sync/push", {
  token: alice.access_token,
  body: {
    changes: {
      categories: [{ id: "e2e-cat", updated_at: Date.now(), name: "E2E" }],
      goals: [{ id: "e2e-goal", updated_at: Date.now(), name: "E2E goal", target_amount: 100 }],
      transactions: [{ ...txn, kind_raw: "expense", category_id: "e2e-cat", updated_at: Date.now() }],
    },
  },
});
check("push categorization + goal", pushed.status === 200 && pushed.body.applied === 3, JSON.stringify(pushed.body));
const after = await pullAll(alice.access_token);
const categorized = after.transactions.find((t) => t.id === txn.id);
check("categorization kept, bank fields untouched", categorized.kind_raw === "expense" && categorized.amount === txn.amount);

const bobView = await pullAll(bob.access_token);
check("other user sees none of it", Object.values(bobView).every((rows) => rows.length === 0));
check("other user can't remove the bank", (await api(`/items/${itemId}`, { method: "DELETE", token: bob.access_token })).status === 404);

const fired = await api("/dev/fire-webhook", { token: alice.access_token, body: { item_id: itemId } });
check("asked Plaid sandbox to fire a signed webhook", fired.status === 200);

const refreshed = await api("/auth/refresh", { body: { refresh_token: alice.refresh_token } });
check("refresh token rotates", refreshed.status === 200 && refreshed.body.refresh_token !== alice.refresh_token);
const token = refreshed.body.access_token;

const removedAlice = await api("/me", { method: "DELETE", token });
const removedBob = await api("/me", { method: "DELETE", token: bob.access_token });
check("account deletion (removes the sandbox bank at Plaid)", removedAlice.status === 204 && removedBob.status === 204);
check("deleted user's token stops working", (await api("/me", { token })).status === 401);

console.log(failures ? `\n${failures} check(s) failed` : "\nAll end-to-end checks passed");
process.exit(failures ? 1 : 0);

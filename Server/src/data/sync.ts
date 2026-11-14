import type { Env, User } from "../env";
import { changes, versionedBatch } from "../lib/db";
import { ApiError, json, object, readBody } from "../lib/http";
import { syncUserItems } from "../plaid/sync";
import { PULL_TABLES, SYNC_TABLES, type Column, type Table } from "./tables";

// The app's sync API. Pull: "what changed since version N?" Push: the app's own edits, newest
// updated_at wins per row. Every query is scoped to the signed-in user's id.

const MAX_PUSH_ROWS = 500;
const DEFAULT_PULL_LIMIT = 500;
const ROW_ID = /^[^\u0000-\u001f]{1,100}$/u;
const DATE = /^\d{4}-\d{2}-\d{2}$/;

type Value = string | number | null;

interface PushRow {
  id: string;
  updatedAt: number;
  deletedAt: number | null;
  values: Record<string, Value>;
}

// MARK: - Pull

function toWire(columns: Column[], row: Record<string, unknown>) {
  const out: Record<string, unknown> = { id: row.id };
  for (const column of columns) {
    const value = row[column.name];
    out[column.name] = column.type === "bool" ? value === 1 : value;
  }
  out.updated_at = row.updated_at;
  out.deleted_at = row.deleted_at;
  out.version = row.version;
  return out;
}

/** GET /sync/changes?since=N&limit=500 */
export async function pullChanges(request: Request, env: Env, user: User): Promise<Response> {
  const url = new URL(request.url);
  const since = Number(url.searchParams.get("since") ?? "0");
  const limit = Number(url.searchParams.get("limit") ?? DEFAULT_PULL_LIMIT);
  if (!Number.isSafeInteger(since) || since < 0) throw new ApiError(400, "invalid_request", "since is invalid.");
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 1000) throw new ApiError(400, "invalid_request", "limit is invalid.");

  const results = await env.DB.batch(
    PULL_TABLES.map((table) =>
      env.DB.prepare(
        `SELECT id, ${table.columns.map((c) => c.name).join(", ")}, updated_at, deleted_at, version
         FROM ${table.name} WHERE user_id = ?1 AND version > ?2 ORDER BY version LIMIT ?3`,
      ).bind(user.id, since, limit),
    ),
  );

  // Each table returned its `limit` oldest changes; the `limit` oldest of all of those are exactly
  // the next page, since versions are unique per user.
  const merged = results.flatMap((result, index) =>
    (result.results as Record<string, unknown>[]).map((row) => ({ table: PULL_TABLES[index], row })),
  );
  merged.sort((a, b) => (a.row.version as number) - (b.row.version as number));
  const page = merged.slice(0, limit);
  const hasMore = merged.length > limit || results.some((result) => result.results.length === limit);

  const changesByTable: Record<string, unknown[]> = {};
  for (const table of PULL_TABLES) changesByTable[table.name] = [];
  for (const { table, row } of page) changesByTable[table.name].push(toWire(table.columns, row));

  const next = page.length ? (page[page.length - 1].row.version as number) : since;
  return json({ changes: changesByTable, next, has_more: hasMore, server_time: Date.now() });
}

// MARK: - Push

function parseValue(table: Table, column: Column, raw: unknown): Value {
  const bad = () => new ApiError(400, "invalid_request", `${table.name}.${column.name} is invalid.`);
  if (raw === undefined) return column.default;
  if (raw === null) {
    if (column.default === null) return null;
    throw bad();
  }
  switch (column.type) {
    case "text":
      if (typeof raw !== "string" || raw.length > (column.max ?? 300)) throw bad();
      return raw;
    case "date":
      if (typeof raw !== "string" || (raw !== "" && !DATE.test(raw))) throw bad();
      return raw;
    case "bool":
      if (raw === true || raw === 1) return 1;
      if (raw === false || raw === 0) return 0;
      throw bad();
    case "int":
    case "ms":
      if (typeof raw !== "number" || !Number.isSafeInteger(raw)) throw bad();
      return raw;
    case "real":
      if (typeof raw !== "number" || !Number.isFinite(raw)) throw bad();
      return raw;
  }
}

function parseRow(table: Table, raw: unknown): PushRow {
  const row = object(raw, `${table.name} row`);
  if (typeof row.id !== "string" || !ROW_ID.test(row.id)) throw new ApiError(400, "invalid_request", `${table.name}.id is invalid.`);
  const updatedAt = row.updated_at;
  if (typeof updatedAt !== "number" || !Number.isSafeInteger(updatedAt) || updatedAt < 0) {
    throw new ApiError(400, "invalid_request", `${table.name}.updated_at is invalid.`);
  }
  const values: Record<string, Value> = {};
  for (const column of table.columns) values[column.name] = parseValue(table, column, row[column.name]);
  return { id: row.id, updatedAt, deletedAt: row.deleted === true ? updatedAt : null, values };
}

const upsertSql = new Map<string, string>();

function upsertStatement(table: Table): string {
  const cached = upsertSql.get(table.name);
  if (cached) return cached;
  const names = table.columns.map((c) => c.name);
  const params = names.map((_, index) => `?${index + 3}`);
  const updatedAt = `?${names.length + 3}`;
  const deletedAt = `?${names.length + 4}`;
  const serverOwned = (expression: string, column: string) =>
    table.plaidKey ? `CASE WHEN ${table.name}.${table.plaidKey} IS NULL THEN ${expression} ELSE ${table.name}.${column} END` : expression;
  const sets = table.columns
    .filter((c) => c.owner !== "insert")
    .map((c) => `${c.name} = ${c.owner === "user" ? `excluded.${c.name}` : serverOwned(`excluded.${c.name}`, c.name)}`);
  const sql = `INSERT INTO ${table.name} (user_id, id, ${names.join(", ")}, updated_at, deleted_at, version)
    VALUES (?1, ?2, ${params.join(", ")}, ${updatedAt}, ${deletedAt}, {version})
    ON CONFLICT (user_id, id) DO UPDATE SET
      ${sets.join(",\n      ")},
      updated_at = excluded.updated_at,
      deleted_at = ${serverOwned("excluded.deleted_at", "deleted_at")},
      version = excluded.version
    WHERE excluded.updated_at >= ${table.name}.updated_at`;
  upsertSql.set(table.name, sql);
  return sql;
}

/** Finds rows that already exist on the server under another id (matched by Plaid id) and adopts that id. */
async function matchPlaidRows(env: Env, user: User, table: Table, rows: PushRow[]): Promise<Map<string, string>> {
  const key = table.plaidKey!;
  const remap = new Map<string, string>();
  const keyed = rows.filter((row) => typeof row.values[key] === "string");
  for (let start = 0; start < keyed.length; start += 90) {
    const chunk = keyed.slice(start, start + 90);
    const placeholders = chunk.map((_, index) => `?${index + 2}`).join(", ");
    const { results } = await env.DB.prepare(`SELECT id, ${key} AS plaid_id FROM ${table.name} WHERE user_id = ?1 AND ${key} IN (${placeholders})`)
      .bind(user.id, ...chunk.map((row) => row.values[key]))
      .all<{ id: string; plaid_id: string }>();
    const existing = new Map(results.map((r) => [r.plaid_id, r.id]));
    for (const row of chunk) {
      const serverId = existing.get(row.values[key] as string);
      if (serverId && serverId !== row.id) {
        remap.set(row.id, serverId);
        row.id = serverId;
      }
    }
  }
  return remap;
}

/** Keeps one row per id (and per Plaid id), preferring the newest edit. */
function dedupe(table: Table, rows: PushRow[]): PushRow[] {
  const seenIds = new Set<string>();
  const seenPlaidIds = new Set<string>();
  const kept: PushRow[] = [];
  for (const row of [...rows].sort((a, b) => b.updatedAt - a.updatedAt)) {
    const plaidId = table.plaidKey ? row.values[table.plaidKey] : null;
    if (seenIds.has(row.id) || (typeof plaidId === "string" && seenPlaidIds.has(plaidId))) continue;
    seenIds.add(row.id);
    if (typeof plaidId === "string") seenPlaidIds.add(plaidId);
    kept.push(row);
  }
  return kept;
}

/** POST /sync/push {changes: {table: [row…]}} */
export async function pushChanges(request: Request, env: Env, user: User): Promise<Response> {
  const body = await readBody(request);
  const incoming = object(body.changes, "changes");
  for (const name of Object.keys(incoming)) {
    if (!SYNC_TABLES.some((table) => table.name === name)) throw new ApiError(400, "invalid_request", `Unknown table ${name}.`);
  }

  let total = 0;
  const parsed: { table: Table; rows: PushRow[] }[] = [];
  for (const table of SYNC_TABLES) {
    const raw = incoming[table.name];
    if (raw === undefined) continue;
    if (!Array.isArray(raw)) throw new ApiError(400, "invalid_request", `${table.name} must be a list.`);
    total += raw.length;
    if (total > MAX_PUSH_ROWS) throw new ApiError(413, "too_many_rows", `Send at most ${MAX_PUSH_ROWS} rows at a time.`);
    parsed.push({ table, rows: dedupe(table, raw.map((row) => parseRow(table, row))) });
  }

  const remapped: { table: string; from: string; to: string }[] = [];
  const accountIds = new Map<string, string>();
  for (const entry of parsed) {
    const { table } = entry;
    for (const row of entry.rows) {
      for (const ref of table.accountRefs ?? []) {
        const to = accountIds.get(row.values[ref] as string);
        if (to) row.values[ref] = to;
      }
    }
    if (table.name === "balance_snapshots") {
      // A snapshot's id is "<account id>:<date>", so both sides name the same day the same way.
      for (const row of entry.rows) row.id = `${row.values.account_id}:${row.values.date}`;
      entry.rows = dedupe(table, entry.rows);
    }
    if (table.plaidKey) {
      const remap = await matchPlaidRows(env, user, table, entry.rows);
      for (const [from, to] of remap) {
        remapped.push({ table: table.name, from, to });
        if (table.name === "accounts") accountIds.set(from, to);
      }
      entry.rows = dedupe(table, entry.rows);
    }
  }

  const batch = versionedBatch(env.DB, user.id);
  for (const { table, rows } of parsed) {
    const sql = upsertStatement(table);
    for (const row of rows) {
      batch.add(sql, row.id, ...table.columns.map((c) => row.values[c.name]), row.updatedAt, row.deletedAt);
    }
  }
  let results: D1Result[];
  try {
    results = await batch.run();
  } catch (error) {
    if (String((error as Error)?.message).includes("UNIQUE")) {
      throw new ApiError(409, "conflict", "Some of these changes collided with newer data. Pull, then try again.");
    }
    throw error;
  }
  const applied = results.filter((result) => changes(result) > 0).length;
  return json({ applied, skipped: batch.size - applied, remapped });
}

/** POST /sync/plaid — asks the server to fetch new bank data now. Returns whether more is still on the way. */
export async function refreshBanks(env: Env, user: User): Promise<Response> {
  return json(await syncUserItems(env, user.id));
}

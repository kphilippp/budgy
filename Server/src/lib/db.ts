/**
 * Writes that the app syncs go through a versioned batch. Each statement touches at most one row
 * and gets its own version number from the user's change counter, reserved inside the same atomic
 * batch, so a reader can never see a later version before an earlier one commits.
 *
 * Statement SQL uses ?1 for the user id, ?2… for its own params, and {version} where the row's
 * version goes.
 */
export function versionedBatch(db: D1Database, userId: string) {
  const items: { sql: string; params: unknown[] }[] = [];
  return {
    add(sql: string, ...params: unknown[]) {
      items.push({ sql, params });
    },
    get size() {
      return items.length;
    },
    async run(): Promise<D1Result[]> {
      const results: D1Result[] = [];
      // D1 batches are transactions; keep each one a sensible size.
      for (let start = 0; start < items.length; start += 100) {
        const chunk = items.slice(start, start + 100);
        const count = chunk.length;
        const statements = [
          db.prepare("UPDATE users SET version = version + ?2 WHERE id = ?1").bind(userId, count),
          ...chunk.map((item, index) =>
            db
              .prepare(item.sql.replaceAll("{version}", `((SELECT version FROM users WHERE id = ?1) - ${count - 1 - index})`))
              .bind(userId, ...item.params.map((value) => (value === undefined ? null : value))),
          ),
        ];
        const batch = await db.batch(statements);
        results.push(...batch.slice(1));
      }
      return results;
    },
  };
}

/** Rows changed by a statement (0 when an upsert's WHERE kept the existing row). */
export const changes = (result: D1Result) => result.meta?.changes ?? 0;

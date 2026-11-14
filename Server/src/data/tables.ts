// The tables the app syncs, mirroring the SwiftData models (snake_case). Each column says who
// may write it from the app:
//   user    the app sets it on insert and update (newest updated_at wins)
//   origin  the app sets it on insert; afterwards only for manual rows, because Plaid-backed rows
//           (those with a plaid key) get these columns from the server's Plaid sync
//   insert  the app may set it only when creating the row (the Plaid ids used for matching)

export type ColumnType = "text" | "int" | "real" | "bool" | "ms" | "date";
export type Owner = "user" | "origin" | "insert";

export interface Column {
  name: string;
  type: ColumnType;
  default: string | number | null;
  owner: Owner;
  max?: number;
}

export interface Table {
  name: string;
  columns: Column[];
  /** Marks Plaid-backed rows; their origin columns and deletion belong to the server. */
  plaidKey?: string;
  /** Columns holding an account id, rewritten when an uploaded account is matched to an existing one. */
  accountRefs?: string[];
}

const col = (name: string, type: ColumnType, def: string | number | null, owner: Owner = "user", max?: number): Column => ({
  name,
  type,
  default: def,
  owner,
  max,
});

/** In push order: rows that others point at come first. */
export const SYNC_TABLES: Table[] = [
  {
    name: "categories",
    columns: [
      col("name", "text", ""),
      col("system_image", "text", "tag.fill"),
      col("color_name", "text", "blue"),
      col("monthly_budget", "real", 0),
      col("sort_order", "int", 0),
      col("system_role", "text", ""),
    ],
  },
  {
    name: "accounts",
    plaidKey: "plaid_account_id",
    columns: [
      col("name", "text", ""),
      col("institution", "text", "", "origin"),
      col("kind_raw", "text", "checking"),
      col("balance", "real", 0, "origin"),
      col("mask", "text", "", "origin"),
      col("last_updated", "ms", null, "origin"),
      col("sort_order", "int", 0),
      col("is_hidden", "bool", 0),
      col("credit_limit", "real", 0),
      col("payment_due_day", "int", 0),
      col("statement_closing_day", "int", 0),
      col("statement_balance", "real", 0),
      col("plaid_account_id", "text", null, "insert"),
      col("plaid_item_id", "text", null, "insert"),
    ],
  },
  {
    name: "recurring_items",
    accountRefs: ["destination_account_id"],
    columns: [
      col("name", "text", ""),
      col("amount", "real", 0),
      col("previous_amount", "real", 0),
      col("frequency_raw", "text", "monthly"),
      col("kind_raw", "text", "subscription"),
      col("next_due_date", "ms", 0),
      col("is_active", "bool", 1),
      col("needs_review", "bool", 0),
      col("system_image", "text", "repeat.circle.fill"),
      col("match_text", "text", ""),
      col("remind_days_before", "int", 2),
      col("last_charged_date", "ms", null),
      col("cancelled_at", "ms", null),
      col("destination_account_id", "text", null),
      col("category_id", "text", null),
    ],
  },
  {
    name: "goals",
    columns: [
      col("name", "text", ""),
      col("system_image", "text", "star.fill"),
      col("color_name", "text", "purple"),
      col("target_amount", "real", 0),
      col("saved_amount", "real", 0),
      col("deadline", "ms", null),
      col("contribution_per_paycheck", "real", 0),
      col("last_funded_period_start", "ms", null),
      col("created_at", "ms", 0),
      col("is_archived", "bool", 0),
      col("sort_order", "int", 0),
    ],
  },
  {
    name: "pay_schedules",
    columns: [
      col("employer_name", "text", "Paycheck"),
      col("frequency_raw", "text", "biweekly"),
      col("anchor_pay_date", "ms", 0),
      col("estimated_amount", "real", 0),
      col("base_amount_override", "real", 0),
      col("match_text", "text", ""),
      col("budget_cycle_day", "int", 0),
      col("monthly_income_override", "real", 0),
      col("checking_buffer", "real", 500),
      col("savings_rate", "real", 0.33),
      col("last_savings_transfer_paycheck_id", "text", null),
    ],
  },
  {
    name: "merchant_rules",
    columns: [col("merchant_key", "text", ""), col("category_id", "text", null), col("kind_raw", "text", "expense")],
  },
  {
    name: "balance_snapshots",
    accountRefs: ["account_id"],
    columns: [col("account_id", "text", ""), col("date", "date", ""), col("balance", "real", 0)],
  },
  {
    name: "transactions",
    plaidKey: "plaid_transaction_id",
    accountRefs: ["account_id"],
    columns: [
      col("account_id", "text", null, "origin"),
      col("name", "text", "", "origin"),
      col("merchant", "text", "", "origin"),
      col("amount", "real", 0, "origin"),
      col("date", "date", "", "origin"),
      col("is_pending", "bool", 0, "origin"),
      col("plaid_transaction_id", "text", null, "insert"),
      col("plaid_category", "text", "", "origin"),
      col("plaid_category_primary", "text", "", "origin"),
      col("kind_raw", "text", null),
      col("notes", "text", "", "user", 2000),
      col("extra_pay_handled", "bool", 0),
      col("needs_category_review", "bool", 0),
      col("category_id", "text", null),
      col("recurring_item_id", "text", null),
    ],
  },
];

/** Everything the app pulls: the synced tables plus read-only bank connection status. */
export const PULL_TABLES: Pick<Table, "name" | "columns">[] = [
  ...SYNC_TABLES,
  {
    name: "plaid_items",
    columns: [
      col("institution_name", "text", ""),
      col("is_investments", "bool", 0),
      col("status", "text", "active"),
      col("last_error", "text", ""),
      col("last_synced_at", "ms", null),
      col("consent_expires_at", "ms", null),
    ],
  },
];

export const tableNamed = (name: string) => SYNC_TABLES.find((table) => table.name === name);

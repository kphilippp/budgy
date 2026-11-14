-- Budgy schema v1.
--
-- Every user-data table is keyed by (user_id, id), so one user's rows can never collide
-- with or overwrite another's. Sync columns on those tables:
--   version     the per-user change counter (users.version) at the row's last change; unique per user
--   updated_at  client clock (ms) of the last edit from the app; newer edits win
--   deleted_at  set when the row is deleted (a tombstone the other devices pull)
-- Times are Unix milliseconds unless the column says otherwise.

CREATE TABLE users (
  id TEXT PRIMARY KEY,
  apple_sub TEXT NOT NULL UNIQUE,
  email TEXT,
  name TEXT NOT NULL DEFAULT '',
  time_zone TEXT,
  apple_refresh_token TEXT,           -- encrypted (src/lib/crypto.ts)
  version INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- Refresh tokens (stored hashed). Each sign-in starts a family; refreshing rotates within it.
CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  family_id TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  rotated_at INTEGER,
  revoked_at INTEGER
);
CREATE INDEX sessions_user ON sessions(user_id);
CREATE INDEX sessions_family ON sessions(family_id);
CREATE INDEX sessions_expiry ON sessions(expires_at);

-- Plaid Link sessions, so a link token can only be completed by the user who created it.
CREATE TABLE link_sessions (
  link_token TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  kind TEXT NOT NULL,                 -- 'bank' | 'investments'
  item_id TEXT,                       -- set in update mode (reconnecting a bank)
  created_at INTEGER NOT NULL,
  completed_at INTEGER
);
CREATE INDEX link_sessions_user ON link_sessions(user_id);

CREATE TABLE plaid_items (
  user_id TEXT NOT NULL,
  id TEXT NOT NULL,                   -- Plaid item_id
  institution_id TEXT,
  institution_name TEXT NOT NULL DEFAULT '',
  is_investments INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'active', -- active | login_required | pending_expiration | pending_disconnect | revoked
  last_error TEXT NOT NULL DEFAULT '',
  last_synced_at INTEGER,
  consent_expires_at INTEGER,
  access_token TEXT,                  -- encrypted; NULL once the item is removed at Plaid
  cursor TEXT NOT NULL DEFAULT '',    -- /transactions/sync cursor after the last complete run
  page_cursor TEXT,                   -- cursor inside an unfinished run
  needs_sync INTEGER NOT NULL DEFAULT 1,
  is_legacy INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER,
  version INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, id)
);
CREATE UNIQUE INDEX plaid_items_item ON plaid_items(id);
CREATE INDEX plaid_items_version ON plaid_items(user_id, version);
CREATE INDEX plaid_items_due ON plaid_items(needs_sync, last_synced_at) WHERE deleted_at IS NULL;

CREATE TABLE accounts (
  user_id TEXT NOT NULL,
  id TEXT NOT NULL,
  name TEXT NOT NULL DEFAULT '',
  institution TEXT NOT NULL DEFAULT '',
  kind_raw TEXT NOT NULL DEFAULT 'checking',
  balance REAL NOT NULL DEFAULT 0,
  mask TEXT NOT NULL DEFAULT '',
  last_updated INTEGER,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_hidden INTEGER NOT NULL DEFAULT 0,
  credit_limit REAL NOT NULL DEFAULT 0,
  payment_due_day INTEGER NOT NULL DEFAULT 0,
  statement_closing_day INTEGER NOT NULL DEFAULT 0,
  statement_balance REAL NOT NULL DEFAULT 0,
  plaid_account_id TEXT,
  plaid_item_id TEXT,
  updated_at INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER,
  version INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, id)
);
CREATE UNIQUE INDEX accounts_plaid ON accounts(user_id, plaid_account_id) WHERE plaid_account_id IS NOT NULL;
CREATE INDEX accounts_version ON accounts(user_id, version);

-- One row per account per day. id = "<account id>:<YYYY-MM-DD>" so the app and server agree on it.
CREATE TABLE balance_snapshots (
  user_id TEXT NOT NULL,
  id TEXT NOT NULL,
  account_id TEXT NOT NULL DEFAULT '',
  date TEXT NOT NULL DEFAULT '',
  balance REAL NOT NULL DEFAULT 0,    -- signed: liabilities are negative
  updated_at INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER,
  version INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, id)
);
CREATE INDEX balance_snapshots_version ON balance_snapshots(user_id, version);

CREATE TABLE categories (
  user_id TEXT NOT NULL,
  id TEXT NOT NULL,
  name TEXT NOT NULL DEFAULT '',
  system_image TEXT NOT NULL DEFAULT 'tag.fill',
  color_name TEXT NOT NULL DEFAULT 'blue',
  monthly_budget REAL NOT NULL DEFAULT 0,
  sort_order INTEGER NOT NULL DEFAULT 0,
  system_role TEXT NOT NULL DEFAULT '',
  updated_at INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER,
  version INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, id)
);
CREATE INDEX categories_version ON categories(user_id, version);

-- Plaid-sourced columns (account_id … plaid_category_primary) are written by the server for
-- Plaid transactions; the app owns the rest. kind_raw stays NULL until the app categorizes it.
CREATE TABLE transactions (
  user_id TEXT NOT NULL,
  id TEXT NOT NULL,
  account_id TEXT,
  name TEXT NOT NULL DEFAULT '',
  merchant TEXT NOT NULL DEFAULT '',
  amount REAL NOT NULL DEFAULT 0,     -- positive = money out (Plaid's convention)
  date TEXT NOT NULL DEFAULT '',      -- YYYY-MM-DD
  is_pending INTEGER NOT NULL DEFAULT 0,
  plaid_transaction_id TEXT,
  pending_transaction_id TEXT,
  plaid_category TEXT NOT NULL DEFAULT '',
  plaid_category_primary TEXT NOT NULL DEFAULT '',
  kind_raw TEXT,
  notes TEXT NOT NULL DEFAULT '',
  extra_pay_handled INTEGER NOT NULL DEFAULT 0,
  needs_category_review INTEGER NOT NULL DEFAULT 0,
  category_id TEXT,
  recurring_item_id TEXT,
  updated_at INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER,
  version INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, id)
);
CREATE UNIQUE INDEX transactions_plaid ON transactions(user_id, plaid_transaction_id) WHERE plaid_transaction_id IS NOT NULL;
CREATE INDEX transactions_version ON transactions(user_id, version);

CREATE TABLE recurring_items (
  user_id TEXT NOT NULL,
  id TEXT NOT NULL,
  name TEXT NOT NULL DEFAULT '',
  amount REAL NOT NULL DEFAULT 0,
  previous_amount REAL NOT NULL DEFAULT 0,
  frequency_raw TEXT NOT NULL DEFAULT 'monthly',
  kind_raw TEXT NOT NULL DEFAULT 'subscription',
  next_due_date INTEGER NOT NULL DEFAULT 0,
  is_active INTEGER NOT NULL DEFAULT 1,
  needs_review INTEGER NOT NULL DEFAULT 0,
  system_image TEXT NOT NULL DEFAULT 'repeat.circle.fill',
  match_text TEXT NOT NULL DEFAULT '',
  remind_days_before INTEGER NOT NULL DEFAULT 2,
  last_charged_date INTEGER,
  cancelled_at INTEGER,
  destination_account_id TEXT,
  category_id TEXT,
  updated_at INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER,
  version INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, id)
);
CREATE INDEX recurring_items_version ON recurring_items(user_id, version);

CREATE TABLE goals (
  user_id TEXT NOT NULL,
  id TEXT NOT NULL,
  name TEXT NOT NULL DEFAULT '',
  system_image TEXT NOT NULL DEFAULT 'star.fill',
  color_name TEXT NOT NULL DEFAULT 'purple',
  target_amount REAL NOT NULL DEFAULT 0,
  saved_amount REAL NOT NULL DEFAULT 0,
  deadline INTEGER,
  contribution_per_paycheck REAL NOT NULL DEFAULT 0,
  last_funded_period_start INTEGER,
  created_at INTEGER NOT NULL DEFAULT 0,
  is_archived INTEGER NOT NULL DEFAULT 0,
  sort_order INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER,
  version INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, id)
);
CREATE INDEX goals_version ON goals(user_id, version);

CREATE TABLE pay_schedules (
  user_id TEXT NOT NULL,
  id TEXT NOT NULL,
  employer_name TEXT NOT NULL DEFAULT 'Paycheck',
  frequency_raw TEXT NOT NULL DEFAULT 'biweekly',
  anchor_pay_date INTEGER NOT NULL DEFAULT 0,
  estimated_amount REAL NOT NULL DEFAULT 0,
  base_amount_override REAL NOT NULL DEFAULT 0,
  match_text TEXT NOT NULL DEFAULT '',
  budget_cycle_day INTEGER NOT NULL DEFAULT 0,
  monthly_income_override REAL NOT NULL DEFAULT 0,
  checking_buffer REAL NOT NULL DEFAULT 500,
  savings_rate REAL NOT NULL DEFAULT 0.33,
  last_savings_transfer_paycheck_id TEXT,
  updated_at INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER,
  version INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, id)
);
CREATE INDEX pay_schedules_version ON pay_schedules(user_id, version);

-- id is the merchant key itself, so two devices that learn the same rule converge on one row.
CREATE TABLE merchant_rules (
  user_id TEXT NOT NULL,
  id TEXT NOT NULL,
  merchant_key TEXT NOT NULL DEFAULT '',
  category_id TEXT,
  kind_raw TEXT NOT NULL DEFAULT 'expense',
  updated_at INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER,
  version INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, id)
);
CREATE INDEX merchant_rules_version ON merchant_rules(user_id, version);

-- One-time markers, such as the legacy relay claim.
CREATE TABLE meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);

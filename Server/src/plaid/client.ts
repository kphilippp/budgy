import type { Env } from "../env";

export class PlaidError extends Error {
  constructor(
    readonly code: string,
    readonly type: string,
    message: string,
    readonly displayMessage: string | null,
  ) {
    super(message);
  }
}

export function plaidHost(env: Env): string {
  return env.PLAID_ENV === "production" ? "https://production.plaid.com" : "https://sandbox.plaid.com";
}

/** Calls a Plaid endpoint. Credentials go in headers; responses and tokens are never logged. */
export async function plaid<T>(env: Env, path: string, payload: Record<string, unknown>): Promise<T> {
  const response = await fetch(`${plaidHost(env)}${path}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "PLAID-CLIENT-ID": env.PLAID_CLIENT_ID,
      "PLAID-SECRET": env.PLAID_SECRET,
    },
    body: JSON.stringify(payload),
  });
  const data = (await response.json().catch(() => ({}))) as Record<string, unknown>;
  if (!response.ok) {
    throw new PlaidError(
      String(data.error_code ?? "PLAID_ERROR"),
      String(data.error_type ?? ""),
      String(data.error_message ?? `Plaid returned ${response.status}`),
      typeof data.display_message === "string" ? data.display_message : null,
    );
  }
  return data as T;
}

/** A short, human message for an item problem, shown in the app next to the bank. */
export function itemErrorMessage(error: PlaidError): string {
  switch (error.code) {
    case "ITEM_LOGIN_REQUIRED":
      return "Your bank needs you to sign in again. Tap Reconnect.";
    case "INSTITUTION_DOWN":
    case "INSTITUTION_NOT_RESPONDING":
      return "Your bank isn't responding right now. Budgy will try again soon.";
    default:
      return error.displayMessage ?? error.message;
  }
}

// MARK: - Response shapes (only the fields Budgy uses)

export interface PlaidAccount {
  account_id: string;
  name: string;
  official_name: string | null;
  mask: string | null;
  type: string;
  subtype: string | null;
  balances: { current: number | null; available: number | null; limit: number | null };
}

export interface PlaidTransaction {
  transaction_id: string;
  account_id: string;
  amount: number;
  date: string;
  name: string;
  merchant_name?: string | null;
  pending: boolean;
  pending_transaction_id?: string | null;
  personal_finance_category?: { primary?: string; detailed?: string } | null;
}

export interface TransactionsSyncResponse {
  added: PlaidTransaction[];
  modified: PlaidTransaction[];
  removed: { transaction_id: string }[];
  next_cursor: string;
  has_more: boolean;
}

/** Maps Plaid's account type to Budgy's AccountKind raw value (same rules the app used before). */
export function accountKind(type: string, subtype: string | null): string {
  const sub = (subtype ?? "").toLowerCase();
  switch (type) {
    case "depository":
      return sub === "savings" || sub === "money market" || sub === "cd" ? "savings" : "checking";
    case "credit":
      return "creditCard";
    case "investment":
      if (sub.includes("401") || sub.includes("403")) return "retirement401k";
      if (sub.includes("roth")) return "rothIRA";
      return "brokerage";
    default:
      return "other";
  }
}

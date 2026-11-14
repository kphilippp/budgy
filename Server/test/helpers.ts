import { createExecutionContext, env, waitOnExecutionContext } from "cloudflare:test";
import { SignJWT, exportJWK, generateKeyPair } from "jose";
import { vi } from "vitest";
import { upsertUser } from "../src/auth/routes";
import { issueSession } from "../src/auth/session";
import type { Env } from "../src/env";
import { sha256Hex } from "../src/lib/crypto";
import worker from "../src/index";

export const testEnv = env as unknown as Env;

// MARK: - Calling the worker

export async function call(
  path: string,
  { method, token, body, headers }: { method?: string; token?: string; body?: unknown; headers?: Record<string, string> } = {},
  overrides: Partial<Env> = {},
): Promise<Response> {
  const requestHeaders = new Headers(headers);
  if (token) requestHeaders.set("authorization", `Bearer ${token}`);
  let payload: string | undefined;
  if (body !== undefined) {
    payload = typeof body === "string" ? body : JSON.stringify(body);
    requestHeaders.set("content-type", "application/json");
  }
  const request = new Request(`https://budgy.test${path}`, { method: method ?? (payload ? "POST" : "GET"), headers: requestHeaders, body: payload });
  const ctx = createExecutionContext();
  const response = await worker.fetch(request as Parameters<typeof worker.fetch>[0], { ...testEnv, ...overrides } as Env, ctx);
  await waitOnExecutionContext(ctx);
  return response;
}

export async function callJson<T = any>(...args: Parameters<typeof call>): Promise<{ status: number; body: T }> {
  const response = await call(...args);
  const text = await response.text();
  return { status: response.status, body: (text ? JSON.parse(text) : null) as T };
}

/** A signed-in user created directly in the database. */
export async function createUser(name = "alice") {
  const { id } = await upsertUser(testEnv, `test:${name}:${crypto.randomUUID()}`, `${name}@example.com`, name, "America/Chicago");
  const tokens = await issueSession(testEnv, id);
  return { id, token: tokens.access_token, refreshToken: tokens.refresh_token };
}

// MARK: - Fake Apple

export const appleKeyPair = await generateKeyPair("RS256", { extractable: true });
export const appleJwk = { ...(await exportJWK(appleKeyPair.publicKey)), kid: "test-apple-key", alg: "RS256", use: "sig" };

export async function appleIdentityToken(options: {
  rawNonce: string;
  sub?: string;
  audience?: string;
  issuer?: string;
  expiresIn?: string | number;
  email?: string;
  signingKey?: CryptoKey;
}): Promise<string> {
  return new SignJWT({ nonce: await sha256Hex(options.rawNonce), email: options.email ?? "person@privaterelay.appleid.com" })
    .setProtectedHeader({ alg: "RS256", kid: "test-apple-key" })
    .setSubject(options.sub ?? "001234.apple-user")
    .setAudience(options.audience ?? "com.kevinphilip.budgy")
    .setIssuer(options.issuer ?? "https://appleid.apple.com")
    .setIssuedAt()
    .setExpirationTime(options.expiresIn ?? "10m")
    .sign(options.signingKey ?? appleKeyPair.privateKey);
}

// MARK: - Fake Plaid webhooks

export const plaidWebhookKeyPair = await generateKeyPair("ES256", { extractable: true });
export const plaidWebhookJwk = { ...(await exportJWK(plaidWebhookKeyPair.publicKey)), kid: "plaid-test-key", alg: "ES256", use: "sig", created_at: 1, expired_at: null };

export async function signedWebhook(payload: object, { issuedAt, tamper }: { issuedAt?: number; tamper?: boolean } = {}) {
  const body = JSON.stringify(payload, null, 2);
  const jwt = await new SignJWT({ request_body_sha256: await sha256Hex(body) })
    .setProtectedHeader({ alg: "ES256", kid: "plaid-test-key", typ: "JWT" })
    .setIssuedAt(issuedAt ?? Math.floor(Date.now() / 1000))
    .sign(plaidWebhookKeyPair.privateKey);
  return { body: tamper ? body.replace("}", ', "x": 1}') : body, headers: { "plaid-verification": jwt } };
}

// MARK: - Outbound fetch mock

export interface RecordedCall {
  url: string;
  body: any;
  headers: Headers;
}

type Handler = (body: any) => unknown | Promise<unknown>;

/**
 * Replaces fetch for the worker under test. Handlers are keyed by path (e.g. "/transactions/sync")
 * or full URL; Apple's key set and Plaid's webhook key are always served.
 */
export function mockFetch(handlers: Record<string, Handler> = {}): RecordedCall[] {
  const calls: RecordedCall[] = [];
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const request = new Request(input, init);
    const url = new URL(request.url);
    const text = request.method === "GET" ? "" : await request.text();
    let body: any = text;
    if (request.headers.get("content-type")?.includes("json")) body = text ? JSON.parse(text) : {};
    else if (request.headers.get("content-type")?.includes("form")) body = Object.fromEntries(new URLSearchParams(text));
    const key = `${url.origin}${url.pathname}`;
    calls.push({ url: key, body, headers: request.headers });

    if (key === "https://appleid.apple.com/auth/keys") return Response.json({ keys: [appleJwk] });
    if (url.pathname === "/webhook_verification_key/get") return Response.json({ key: plaidWebhookJwk });
    const handler = handlers[key] ?? handlers[url.pathname];
    if (!handler) return Response.json({ error_code: "NOT_MOCKED", error_message: `No mock for ${key}` }, { status: 400 });
    const result = await handler(body);
    return result instanceof Response ? result : Response.json(result);
  });
  return calls;
}

export function plaidError(code: string, status = 400) {
  return Response.json({ error_code: code, error_type: "ITEM_ERROR", error_message: `mock ${code}`, display_message: null }, { status });
}

// MARK: - Data helpers

export async function seedItem(userId: string, itemId: string, { accessToken = `access-test-${itemId}`, isInvestments = false } = {}) {
  const { seal, plaidTokenContext } = await import("../src/lib/crypto");
  await testEnv.DB.prepare(
    `INSERT INTO plaid_items (user_id, id, institution_name, is_investments, access_token, needs_sync, created_at, updated_at)
     VALUES (?1, ?2, 'Test Bank', ?3, ?4, 1, ?5, ?5)`,
  )
    .bind(userId, itemId, isInvestments ? 1 : 0, await seal(testEnv, accessToken, plaidTokenContext(userId, itemId)), Date.now())
    .run();
}

export const plaidAccount = (id: string, overrides: Partial<{ type: string; subtype: string; current: number; limit: number | null }> = {}) => ({
  account_id: id,
  name: `Account ${id}`,
  official_name: null,
  mask: "1234",
  type: overrides.type ?? "depository",
  subtype: overrides.subtype ?? "checking",
  balances: { current: overrides.current ?? 1000, available: null, limit: overrides.limit ?? null },
});

export const plaidTransaction = (id: string, accountId: string, overrides: Record<string, unknown> = {}) => ({
  transaction_id: id,
  account_id: accountId,
  amount: 12.5,
  date: "2026-11-10",
  name: "COFFEE SHOP 123",
  merchant_name: "Coffee Shop",
  pending: false,
  pending_transaction_id: null,
  personal_finance_category: { primary: "FOOD_AND_DRINK", detailed: "FOOD_AND_DRINK_COFFEE" },
  ...overrides,
});

import { afterEach, describe, expect, it, vi } from "vitest";
import { appleIdentityToken, call, callJson, createUser, mockFetch, plaidAccount, plaidTransaction, seedItem } from "./helpers";

afterEach(() => vi.restoreAllMocks());

describe("API hygiene", () => {
  it("reports health with the environment", async () => {
    const response = await callJson("/health");
    expect(response.status).toBe(200);
    expect(response.body).toMatchObject({ ok: true, env: "production", plaid_env: "production" });
  });

  it("answers unknown routes and bad input with JSON errors", async () => {
    const user = await createUser();
    expect(await callJson("/nope")).toEqual({ status: 404, body: { error: { code: "not_found", message: "Not found." } } });
    expect((await callJson("/sync/push", { token: user.token, body: "{not json" })).status).toBe(400);
    expect((await callJson("/sync/changes?since=-1", { token: user.token })).status).toBe(400);
    const huge = await call("/sync/push", { token: user.token, body: "x", headers: { "content-length": String(10 * 1024 * 1024) } });
    expect(huge.status).toBe(413);
  });

  it("requires a session for every data route", async () => {
    for (const [method, path] of [
      ["GET", "/me"],
      ["DELETE", "/me"],
      ["GET", "/sync/changes"],
      ["POST", "/sync/push"],
      ["POST", "/sync/plaid"],
      ["POST", "/link/create"],
      ["POST", "/link/complete"],
      ["DELETE", "/items/x"],
      ["POST", "/migrate/claim-legacy"],
    ]) {
      expect((await call(path, { method, body: method === "POST" ? {} : undefined })).status, `${method} ${path}`).toBe(401);
    }
  });

  it("hides the dev-only routes in production", async () => {
    expect((await call("/dev/login", { body: { secret: "x", name: "a" } })).status).toBe(404);
  });

  it("never logs tokens or financial data", async () => {
    const lines: string[] = [];
    for (const level of ["log", "warn", "error", "info"] as const) {
      vi.spyOn(console, level).mockImplementation((...args: unknown[]) => void lines.push(args.map(String).join(" ")));
    }
    mockFetch({
      "https://appleid.apple.com/auth/token": () => ({ refresh_token: "apple-refresh-SECRET" }),
      "/accounts/get": () => ({ accounts: [plaidAccount("pa-1", { current: 4321.09 })] }),
      "/transactions/sync": () => ({ added: [plaidTransaction("t1", "pa-1", { amount: 77.77, name: "PHARMACY 1" })], modified: [], removed: [], next_cursor: "c", has_more: false }),
    });
    const signIn = await callJson("/auth/apple", {
      body: { identity_token: await appleIdentityToken({ rawNonce: "n", sub: "log-test" }), raw_nonce: "n", authorization_code: "c" },
    });
    await seedItem(signIn.body.user.id, "item-1", { accessToken: "access-production-LOGTEST" });
    await callJson("/sync/plaid", { token: signIn.body.access_token, body: {} });
    await callJson("/sync/changes", { token: signIn.body.access_token });

    const logs = lines.join("\n");
    expect(logs).toContain('"event":"request"');
    for (const secret of [signIn.body.access_token, signIn.body.refresh_token, "apple-refresh-SECRET", "access-production-LOGTEST", "4321.09", "77.77", "PHARMACY"]) {
      expect(logs).not.toContain(secret);
    }
  });
});

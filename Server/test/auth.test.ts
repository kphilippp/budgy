import { decodeProtectedHeader, generateKeyPair } from "jose";
import { afterEach, describe, expect, it, vi } from "vitest";
import { appleIdentityToken, callJson, createUser, mockFetch, testEnv } from "./helpers";

afterEach(() => vi.restoreAllMocks());

const signIn = (body: Record<string, unknown>) => callJson("/auth/apple", { body });

describe("POST /auth/apple", () => {
  it("creates a user from a valid Apple token and keeps Apple's refresh token encrypted", async () => {
    const calls = mockFetch({ "https://appleid.apple.com/auth/token": () => ({ refresh_token: "apple-refresh-SECRET" }) });
    const first = await signIn({
      identity_token: await appleIdentityToken({ rawNonce: "nonce-1", sub: "apple-sub-new" }),
      raw_nonce: "nonce-1",
      authorization_code: "code-1",
      full_name: "Kevin P",
      time_zone: "America/Chicago",
    });
    expect(first.status).toBe(200);
    expect(first.body).toMatchObject({ token_type: "Bearer", expires_in: 3600, is_new_user: true, user: { name: "Kevin P" } });
    expect(first.body.refresh_token).toEqual(expect.any(String));

    // The code exchange authenticates with an ES256 client secret for our bundle ID.
    const exchange = calls.find((c) => c.url === "https://appleid.apple.com/auth/token")!;
    expect(exchange.body).toMatchObject({ client_id: "com.kevinphilip.budgy", grant_type: "authorization_code", code: "code-1" });
    expect(decodeProtectedHeader(exchange.body.client_secret)).toMatchObject({ alg: "ES256", kid: "TESTKEY123" });

    const stored = await testEnv.DB.prepare("SELECT apple_refresh_token FROM users WHERE apple_sub = 'apple-sub-new'").first<string>("apple_refresh_token");
    expect(stored).toMatch(/^v1\./);
    expect(stored).not.toContain("apple-refresh-SECRET");

    // Signing in again finds the same user and keeps the name Apple only sent the first time.
    const again = await signIn({ identity_token: await appleIdentityToken({ rawNonce: "nonce-2", sub: "apple-sub-new" }), raw_nonce: "nonce-2" });
    expect(again.status).toBe(200);
    expect(again.body).toMatchObject({ is_new_user: false, user: { id: first.body.user.id, name: "Kevin P" } });
  });

  it.each([
    ["the wrong audience", { audience: "com.someone.else" }],
    ["the wrong issuer", { issuer: "https://appleid.example.com" }],
    ["an expiry in the past", { expiresIn: Math.floor(Date.now() / 1000) - 60 }],
  ])("rejects a token with %s", async (_label, options) => {
    mockFetch();
    const response = await signIn({ identity_token: await appleIdentityToken({ rawNonce: "n", ...options }), raw_nonce: "n" });
    expect(response.status).toBe(401);
    expect(response.body.error.code).toBe("invalid_apple_token");
  });

  it("rejects a token signed by a key that isn't Apple's", async () => {
    mockFetch();
    const impostor = await generateKeyPair("RS256");
    const response = await signIn({ identity_token: await appleIdentityToken({ rawNonce: "n", signingKey: impostor.privateKey }), raw_nonce: "n" });
    expect(response.status).toBe(401);
  });

  it("rejects a token whose nonce doesn't match the raw nonce", async () => {
    mockFetch();
    const response = await signIn({ identity_token: await appleIdentityToken({ rawNonce: "the-real-nonce" }), raw_nonce: "a-replayed-nonce" });
    expect(response.status).toBe(401);
  });

  it("requires the token and nonce", async () => {
    expect((await signIn({ raw_nonce: "n" })).status).toBe(400);
    expect((await signIn({ identity_token: "x" })).status).toBe(400);
  });
});

describe("sessions", () => {
  const refresh = (token: string) => callJson("/auth/refresh", { body: { refresh_token: token } });

  it("rotates the refresh token on every refresh", async () => {
    const user = await createUser();
    const first = await refresh(user.refreshToken);
    expect(first.status).toBe(200);
    expect(first.body.refresh_token).not.toBe(user.refreshToken);
    const second = await refresh(first.body.refresh_token);
    expect(second.status).toBe(200);
    expect((await callJson("/me", { token: second.body.access_token })).status).toBe(200);
  });

  it("allows a quick retry of the same refresh (a lost response)", async () => {
    const user = await createUser();
    expect((await refresh(user.refreshToken)).status).toBe(200);
    expect((await refresh(user.refreshToken)).status).toBe(200);
  });

  it("treats a later reuse of an old refresh token as theft and ends that session everywhere", async () => {
    const user = await createUser();
    const rotated = await refresh(user.refreshToken);
    await testEnv.DB.prepare("UPDATE sessions SET rotated_at = rotated_at - 120000 WHERE rotated_at IS NOT NULL").run();
    const reused = await refresh(user.refreshToken);
    expect(reused.status).toBe(401);
    expect(reused.body.error.code).toBe("session_reused");
    expect((await refresh(rotated.body.refresh_token)).status).toBe(401);
  });

  it("signs out", async () => {
    const user = await createUser();
    const out = await callJson("/auth/signout", { body: { refresh_token: user.refreshToken } });
    expect(out.status).toBe(204);
    expect((await refresh(user.refreshToken)).status).toBe(401);
  });

  it("rejects missing, malformed, and forged access tokens", async () => {
    expect((await callJson("/me")).status).toBe(401);
    expect((await callJson("/me", { token: "not-a-token" })).status).toBe(401);
    const user = await createUser();
    const [header, payload] = user.token.split(".");
    expect((await callJson("/me", { token: `${header}.${payload}.forged-signature` })).status).toBe(401);
  });
});

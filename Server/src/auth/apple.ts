import { SignJWT, createRemoteJWKSet, importPKCS8, jwtVerify } from "jose";
import type { Env } from "../env";
import { constantTimeEqual, sha256Hex } from "../lib/crypto";
import { ApiError } from "../lib/http";

const APPLE_ISSUER = "https://appleid.apple.com";

// Apple's signing keys, cached per isolate; jose refetches when it sees an unknown key id.
const appleKeys = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"), {
  cacheMaxAge: 6 * 60 * 60 * 1000,
  cooldownDuration: 30 * 1000,
});

export interface AppleIdentity {
  sub: string;
  email: string | null;
}

/**
 * Verifies a Sign in with Apple identity token: RS256 signature against Apple's keys, issuer,
 * audience (our bundle ID), expiry, and that its nonce is the SHA-256 of the app's raw nonce.
 */
export async function verifyIdentityToken(env: Env, identityToken: string, rawNonce: string): Promise<AppleIdentity> {
  const invalid = new ApiError(401, "invalid_apple_token", "Sign in with Apple couldn't be verified. Please try again.");
  let payload;
  try {
    ({ payload } = await jwtVerify(identityToken, appleKeys, {
      issuer: APPLE_ISSUER,
      audience: env.APPLE_BUNDLE_ID,
      algorithms: ["RS256"],
    }));
  } catch {
    throw invalid;
  }
  const expectedNonce = await sha256Hex(rawNonce);
  if (typeof payload.nonce !== "string" || !constantTimeEqual(payload.nonce, expectedNonce)) throw invalid;
  if (typeof payload.sub !== "string" || payload.sub.length === 0) throw invalid;
  return { sub: payload.sub, email: typeof payload.email === "string" ? payload.email : null };
}

/** The ES256 client secret Apple's token endpoints require, signed with the Sign in with Apple key. */
async function clientSecret(env: Env): Promise<string> {
  const key = await importPKCS8(env.APPLE_SIWA_PRIVATE_KEY!, "ES256");
  return new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: env.APPLE_SIWA_KEY_ID })
    .setIssuer(env.APPLE_TEAM_ID)
    .setSubject(env.APPLE_BUNDLE_ID)
    .setAudience(APPLE_ISSUER)
    .setIssuedAt()
    .setExpirationTime("5m")
    .sign(key);
}

/** Exchanges the one-time authorization code for Apple's refresh token, kept so account deletion can revoke it. */
export async function exchangeAuthorizationCode(env: Env, code: string): Promise<string | null> {
  if (!env.APPLE_SIWA_PRIVATE_KEY) return null;
  const response = await fetch("https://appleid.apple.com/auth/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: env.APPLE_BUNDLE_ID,
      client_secret: await clientSecret(env),
      code,
      grant_type: "authorization_code",
    }),
  });
  if (!response.ok) {
    console.warn(JSON.stringify({ event: "apple_code_exchange_failed", status: response.status }));
    return null;
  }
  const data = await response.json<{ refresh_token?: string }>();
  return data.refresh_token ?? null;
}

/** Revokes Apple's refresh token (part of account deletion). Returns whether Apple accepted it. */
export async function revokeAppleToken(env: Env, refreshToken: string): Promise<boolean> {
  if (!env.APPLE_SIWA_PRIVATE_KEY) return false;
  const response = await fetch("https://appleid.apple.com/auth/revoke", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: env.APPLE_BUNDLE_ID,
      client_secret: await clientSecret(env),
      token: refreshToken,
      token_type_hint: "refresh_token",
    }),
  });
  if (!response.ok) console.warn(JSON.stringify({ event: "apple_revoke_failed", status: response.status }));
  return response.ok;
}

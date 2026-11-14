import type { Env } from "../env";
import { appleTokenContext, seal } from "../lib/crypto";
import { ApiError, json, noContent, optionalString, readBody, string, timeZone } from "../lib/http";
import { exchangeAuthorizationCode, verifyIdentityToken } from "./apple";
import { issueSession, refreshSession, signOut } from "./session";

export interface Profile {
  id: string;
  email: string | null;
  name: string;
  created_at: number;
}

export async function loadProfile(env: Env, userId: string): Promise<Profile> {
  const profile = await env.DB.prepare("SELECT id, email, name, created_at FROM users WHERE id = ?1").bind(userId).first<Profile>();
  if (!profile) throw new ApiError(401, "invalid_token", "Your session expired. Please sign in again.");
  return profile;
}

/** Limits sign-in attempts per IP address. A no-op where the rate limiter isn't bound (tests). */
export async function limitAuthAttempts(request: Request, env: Env): Promise<void> {
  if (!env.AUTH_LIMITER) return;
  const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
  const { success } = await env.AUTH_LIMITER.limit({ key: `auth:${ip}` });
  if (!success) throw new ApiError(429, "rate_limited", "Too many attempts. Wait a minute and try again.");
}

/** Creates the user on first sign-in, or updates what Apple shared. Returns the user id and whether it's new. */
export async function upsertUser(
  env: Env,
  appleSub: string,
  email: string | null,
  name: string | undefined,
  zone: string | undefined,
): Promise<{ id: string; isNew: boolean }> {
  const now = Date.now();
  const id = crypto.randomUUID();
  const row = await env.DB.prepare(
    `INSERT INTO users (id, apple_sub, email, name, time_zone, created_at, updated_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)
     ON CONFLICT (apple_sub) DO UPDATE SET
       email = COALESCE(excluded.email, users.email),
       name = CASE WHEN users.name = '' THEN excluded.name ELSE users.name END,
       time_zone = COALESCE(excluded.time_zone, users.time_zone),
       updated_at = excluded.updated_at
     RETURNING id`,
  )
    .bind(id, appleSub, email, name ?? "", zone ?? null, now)
    .first<{ id: string }>();
  return { id: row!.id, isNew: row!.id === id };
}

/** POST /auth/apple — exchange a Sign in with Apple result for a Budgy session. */
export async function signInWithApple(request: Request, env: Env): Promise<Response> {
  await limitAuthAttempts(request, env);
  const body = await readBody(request, 32 * 1024);
  const identityToken = string(body, "identity_token", { max: 8192 });
  const rawNonce = string(body, "raw_nonce", { max: 256 });
  const authorizationCode = optionalString(body, "authorization_code", { max: 1024 });
  // Apple shares the name only on the very first authorization, and only with the app.
  const fullName = optionalString(body, "full_name", { max: 200 })?.trim();
  const zone = timeZone(body);

  const identity = await verifyIdentityToken(env, identityToken, rawNonce);
  const user = await upsertUser(env, identity.sub, identity.email, fullName, zone);

  if (authorizationCode) {
    const appleRefreshToken = await exchangeAuthorizationCode(env, authorizationCode);
    if (appleRefreshToken) {
      await env.DB.prepare("UPDATE users SET apple_refresh_token = ?2 WHERE id = ?1")
        .bind(user.id, await seal(env, appleRefreshToken, appleTokenContext(user.id)))
        .run();
    }
  }

  const tokens = await issueSession(env, user.id);
  return json({ ...tokens, user: await loadProfile(env, user.id), is_new_user: user.isNew });
}

/** POST /auth/refresh — rotate the refresh token and get a new access token. */
export async function refresh(request: Request, env: Env): Promise<Response> {
  await limitAuthAttempts(request, env);
  const body = await readBody(request, 8 * 1024);
  const { userId, tokens } = await refreshSession(env, string(body, "refresh_token", { max: 256 }));
  const zone = timeZone(body);
  if (zone) await env.DB.prepare("UPDATE users SET time_zone = ?2 WHERE id = ?1").bind(userId, zone).run();
  return json({ ...tokens, user: await loadProfile(env, userId) });
}

/** POST /auth/signout — end this device's session. Always succeeds. */
export async function signOutRoute(request: Request, env: Env): Promise<Response> {
  const body = await readBody(request, 8 * 1024);
  const token = optionalString(body, "refresh_token", { max: 256 });
  if (token) await signOut(env, token);
  return noContent();
}

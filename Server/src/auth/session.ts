import { SignJWT, jwtVerify } from "jose";
import type { Env, User } from "../env";
import { base64Decode, randomToken, sha256Hex } from "../lib/crypto";
import { ApiError } from "../lib/http";

const ACCESS_TOKEN_SECONDS = 60 * 60;
const REFRESH_TOKEN_MS = 90 * 24 * 60 * 60 * 1000;
/** A refresh retried this soon after it succeeded is a lost response, not a stolen token. */
const REFRESH_RETRY_GRACE_MS = 60 * 1000;

export interface SessionTokens {
  access_token: string;
  token_type: "Bearer";
  expires_in: number;
  refresh_token: string;
}

function signingKey(env: Env): Uint8Array {
  const key = base64Decode(env.SESSION_SIGNING_KEY ?? "");
  if (key.length < 32) throw new Error("SESSION_SIGNING_KEY must be at least 32 bytes");
  return key;
}

const unauthorized = (code = "unauthorized", message = "Please sign in again.") => new ApiError(401, code, message);

/** Starts a session (or continues a refresh-token family) and returns a fresh token pair. */
export async function issueSession(env: Env, userId: string, familyId: string = crypto.randomUUID()): Promise<SessionTokens> {
  const refreshToken = randomToken(32);
  const now = Date.now();
  await env.DB.prepare(
    "INSERT INTO sessions (id, user_id, family_id, token_hash, created_at, expires_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
  )
    .bind(crypto.randomUUID(), userId, familyId, await sha256Hex(refreshToken), now, now + REFRESH_TOKEN_MS)
    .run();
  const accessToken = await new SignJWT({})
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setSubject(userId)
    .setIssuer("budgy")
    .setAudience(env.ENVIRONMENT)
    .setIssuedAt()
    .setExpirationTime(`${ACCESS_TOKEN_SECONDS}s`)
    .sign(signingKey(env));
  return { access_token: accessToken, token_type: "Bearer", expires_in: ACCESS_TOKEN_SECONDS, refresh_token: refreshToken };
}

interface SessionRow {
  id: string;
  user_id: string;
  family_id: string;
  expires_at: number;
  rotated_at: number | null;
  revoked_at: number | null;
}

/** Rotates a refresh token. Reusing an old one (outside a short retry window) revokes the whole family. */
export async function refreshSession(env: Env, refreshToken: string): Promise<{ userId: string; tokens: SessionTokens }> {
  const row = await env.DB.prepare(
    "SELECT id, user_id, family_id, expires_at, rotated_at, revoked_at FROM sessions WHERE token_hash = ?1",
  )
    .bind(await sha256Hex(refreshToken))
    .first<SessionRow>();
  const now = Date.now();
  if (!row || row.revoked_at || row.expires_at < now) throw unauthorized("session_expired");
  if (row.rotated_at && now - row.rotated_at > REFRESH_RETRY_GRACE_MS) {
    await revokeFamily(env, row.family_id);
    console.warn(JSON.stringify({ event: "refresh_token_reused", family: row.family_id.slice(0, 8) }));
    throw unauthorized("session_reused");
  }
  const user = await env.DB.prepare("SELECT id FROM users WHERE id = ?1").bind(row.user_id).first();
  if (!user) throw unauthorized("session_expired");
  await env.DB.prepare("UPDATE sessions SET rotated_at = COALESCE(rotated_at, ?2) WHERE id = ?1").bind(row.id, now).run();
  return { userId: row.user_id, tokens: await issueSession(env, row.user_id, row.family_id) };
}

export async function revokeFamily(env: Env, familyId: string): Promise<void> {
  await env.DB.prepare("UPDATE sessions SET revoked_at = ?2 WHERE family_id = ?1 AND revoked_at IS NULL")
    .bind(familyId, Date.now())
    .run();
}

/** Signs out the device holding this refresh token. Unknown tokens are ignored. */
export async function signOut(env: Env, refreshToken: string): Promise<void> {
  const row = await env.DB.prepare("SELECT family_id FROM sessions WHERE token_hash = ?1")
    .bind(await sha256Hex(refreshToken))
    .first<{ family_id: string }>();
  if (row) await revokeFamily(env, row.family_id);
}

/** Resolves the signed-in user from `Authorization: Bearer <access token>`, or throws 401. */
export async function authenticate(request: Request, env: Env): Promise<User> {
  const header = request.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(\S+)$/i.exec(header);
  if (!match) throw unauthorized();
  let userId: string;
  try {
    const { payload } = await jwtVerify(match[1], signingKey(env), {
      issuer: "budgy",
      audience: env.ENVIRONMENT,
      algorithms: ["HS256"],
    });
    if (typeof payload.sub !== "string") throw new Error("no subject");
    userId = payload.sub;
  } catch {
    throw unauthorized("invalid_token", "Your session expired. Please sign in again.");
  }
  // A deleted account's tokens stop working immediately.
  const user = await env.DB.prepare("SELECT id, time_zone FROM users WHERE id = ?1").bind(userId).first<User>();
  if (!user) throw unauthorized("invalid_token", "Your session expired. Please sign in again.");
  return user;
}

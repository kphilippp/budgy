import type { Env } from "../env";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Decodes standard or URL-safe base64. */
export function base64Decode(text: string): Uint8Array {
  const normalized = text.trim().replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
  return Uint8Array.from(atob(padded), (char) => char.charCodeAt(0));
}

/** A random, URL-safe token with `bytes` bytes of entropy. */
export function randomToken(bytes = 32): string {
  return base64UrlEncode(crypto.getRandomValues(new Uint8Array(bytes)));
}

export async function sha256Hex(input: string | Uint8Array): Promise<string> {
  const data = typeof input === "string" ? encoder.encode(input) : input;
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", data));
  return Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function constantTimeEqual(a: string, b: string): boolean {
  const left = encoder.encode(a);
  const right = encoder.encode(b);
  if (left.length !== right.length) return false;
  return crypto.subtle.timingSafeEqual(left, right);
}

// MARK: - Encryption at rest (AES-256-GCM)
//
// Sealed values look like "v2.<iv>.<ciphertext>": the key version travels with the ciphertext,
// so a new key can be added to TOKEN_KEYS without breaking old values. `context` (for example
// "<user id>:plaid:<item id>") is bound in as additional data, so a ciphertext copied onto
// another user's row won't decrypt.

interface KeyRing {
  source: string;
  current: number;
  keys: Map<number, CryptoKey>;
}

let cachedRing: Promise<KeyRing> | undefined;

async function keyRing(env: Env): Promise<KeyRing> {
  const source = env.TOKEN_KEYS;
  const existing = cachedRing && (await cachedRing);
  if (existing && existing.source === source) return existing;
  cachedRing = (async () => {
    let parsed: Record<string, string>;
    try {
      parsed = JSON.parse(source);
    } catch {
      throw new Error("TOKEN_KEYS is not valid JSON");
    }
    const keys = new Map<number, CryptoKey>();
    for (const [version, material] of Object.entries(parsed)) {
      const raw = base64Decode(material);
      if (raw.length !== 32) throw new Error(`TOKEN_KEYS version ${version} must be 32 bytes`);
      keys.set(Number(version), await crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]));
    }
    if (keys.size === 0) throw new Error("TOKEN_KEYS has no keys");
    return { source, current: Math.max(...keys.keys()), keys };
  })();
  return cachedRing;
}

export async function seal(env: Env, plaintext: string, context: string): Promise<string> {
  const ring = await keyRing(env);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: encoder.encode(context) },
    ring.keys.get(ring.current)!,
    encoder.encode(plaintext),
  );
  return `v${ring.current}.${base64UrlEncode(iv)}.${base64UrlEncode(new Uint8Array(ciphertext))}`;
}

export async function unseal(env: Env, sealed: string, context: string): Promise<string> {
  const match = /^v(\d+)\.([\w-]+)\.([\w-]+)$/.exec(sealed);
  if (!match) throw new Error("Malformed sealed value");
  const ring = await keyRing(env);
  const key = ring.keys.get(Number(match[1]));
  if (!key) throw new Error(`No TOKEN_KEYS entry for version ${match[1]}`);
  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: base64Decode(match[2]), additionalData: encoder.encode(context) },
    key,
    base64Decode(match[3]),
  );
  return decoder.decode(plaintext);
}

export const plaidTokenContext = (userId: string, itemId: string) => `${userId}:plaid:${itemId}`;
export const appleTokenContext = (userId: string) => `${userId}:apple`;

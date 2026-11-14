/** Bindings, variables, and secrets the worker runs with. See wrangler.toml and Server/README.md. */
export interface Env {
  DB: D1Database;
  /** The old single-user relay's KV namespace. Production only, until the legacy claim is cleaned up. */
  LEGACY_ITEMS?: KVNamespace;
  AUTH_LIMITER?: RateLimit;
  CF_VERSION_METADATA?: WorkerVersionMetadata;

  ENVIRONMENT: "production" | "dev";
  PLAID_ENV: "production" | "sandbox";
  /** This worker's own base URL, e.g. https://budgy.example.workers.dev (used for Plaid webhooks). */
  PUBLIC_URL: string;
  APPLE_BUNDLE_ID: string;
  APPLE_TEAM_ID: string;
  APPLE_SIWA_KEY_ID: string;

  // Secrets
  PLAID_CLIENT_ID: string;
  PLAID_SECRET: string;
  /** JSON map of key version to base64 AES-256 key, e.g. {"1":"…"}. The highest version encrypts. */
  TOKEN_KEYS: string;
  /** Base64, at least 32 bytes. Signs Budgy's own access tokens. */
  SESSION_SIGNING_KEY: string;
  /** Contents of the Sign in with Apple .p8 key. */
  APPLE_SIWA_PRIVATE_KEY?: string;
  /** The Budgy user allowed to claim the old relay's bank connections. Production only. */
  LEGACY_OWNER_USER_ID?: string;
  /** Enables /dev/login in the dev environment only. */
  DEV_TEST_LOGIN_SECRET?: string;
}

export interface User {
  id: string;
  time_zone: string | null;
}

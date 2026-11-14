import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { generateKeyPairSync, randomBytes } from "node:crypto";
import path from "node:path";
import { defineConfig } from "vitest/config";

// Tests run inside the Workers runtime against a local D1 with the real migrations applied.
// Secrets are throwaway values generated per run; outbound calls to Plaid and Apple are mocked.

const migrations = await readD1Migrations(path.join(import.meta.dirname, "migrations"));
const appleKey = generateKeyPairSync("ec", { namedCurve: "P-256" }).privateKey.export({ type: "pkcs8", format: "pem" }).toString();

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        bindings: {
          TEST_MIGRATIONS: migrations,
          PLAID_CLIENT_ID: "test-client-id",
          PLAID_SECRET: "test-secret",
          TOKEN_KEYS: JSON.stringify({ "1": randomBytes(32).toString("base64") }),
          SESSION_SIGNING_KEY: randomBytes(32).toString("base64"),
          APPLE_SIWA_PRIVATE_KEY: appleKey,
          APPLE_SIWA_KEY_ID: "TESTKEY123",
        },
      },
    }),
  ],
  test: {
    setupFiles: ["./test/setup.ts"],
  },
});

import { deleteMe, getMe } from "./account";
import { refresh, signInWithApple, signOutRoute } from "./auth/routes";
import { authenticate } from "./auth/session";
import { pullChanges, pushChanges, refreshBanks } from "./data/sync";
import { PULL_TABLES } from "./data/tables";
import { devFireWebhook, devLogin, devRoutesEnabled, devSandboxItem } from "./dev";
import type { Env } from "./env";
import { claimLegacyItems } from "./legacy";
import { ApiError, errorResponse, json } from "./lib/http";
import { PlaidError, itemErrorMessage } from "./plaid/client";
import { completeLink, createLink, removeItem } from "./plaid/link";
import { runScheduledSync } from "./plaid/sync";
import { handlePlaidWebhook } from "./plaid/webhook";

// Budgy's API. Every data route is scoped to the signed-in user; see Server/README.md.

type Handler = (request: Request, env: Env, ctx: ExecutionContext, params: string[]) => Promise<Response>;

const authed =
  (handler: (request: Request, env: Env, user: Awaited<ReturnType<typeof authenticate>>, ctx: ExecutionContext, params: string[]) => Promise<Response>): Handler =>
  async (request, env, ctx, params) =>
    handler(request, env, await authenticate(request, env), ctx, params);

const routes: { method: string; pattern: RegExp; label: string; handler: Handler; dev?: true }[] = [
  { method: "GET", pattern: /^\/health$/, label: "/health", handler: async (_r, env) => health(env) },
  { method: "POST", pattern: /^\/auth\/apple$/, label: "/auth/apple", handler: (r, env) => signInWithApple(r, env) },
  { method: "POST", pattern: /^\/auth\/refresh$/, label: "/auth/refresh", handler: (r, env) => refresh(r, env) },
  { method: "POST", pattern: /^\/auth\/signout$/, label: "/auth/signout", handler: (r, env) => signOutRoute(r, env) },
  { method: "GET", pattern: /^\/me$/, label: "/me", handler: authed((_r, env, user) => getMe(env, user)) },
  { method: "DELETE", pattern: /^\/me$/, label: "/me", handler: authed((_r, env, user) => deleteMe(env, user)) },
  { method: "GET", pattern: /^\/sync\/changes$/, label: "/sync/changes", handler: authed((r, env, user) => pullChanges(r, env, user)) },
  { method: "POST", pattern: /^\/sync\/push$/, label: "/sync/push", handler: authed((r, env, user) => pushChanges(r, env, user)) },
  { method: "POST", pattern: /^\/sync\/plaid$/, label: "/sync/plaid", handler: authed((_r, env, user) => refreshBanks(env, user)) },
  { method: "POST", pattern: /^\/link\/create$/, label: "/link/create", handler: authed((r, env, user) => createLink(r, env, user)) },
  { method: "POST", pattern: /^\/link\/complete$/, label: "/link/complete", handler: authed((r, env, user, ctx) => completeLink(r, env, user, ctx)) },
  { method: "DELETE", pattern: /^\/items\/([^/]+)$/, label: "/items/:id", handler: authed((_r, env, user, _ctx, [id]) => removeItem(env, user, decodeURIComponent(id))) },
  { method: "POST", pattern: /^\/plaid\/webhook$/, label: "/plaid/webhook", handler: (r, env, ctx) => handlePlaidWebhook(r, env, ctx) },
  { method: "POST", pattern: /^\/migrate\/claim-legacy$/, label: "/migrate/claim-legacy", handler: authed((_r, env, user) => claimLegacyItems(env, user)) },
  { method: "POST", pattern: /^\/dev\/login$/, label: "/dev/login", handler: (r, env) => devLogin(r, env), dev: true },
  { method: "POST", pattern: /^\/dev\/sandbox-item$/, label: "/dev/sandbox-item", handler: (r, env, ctx) => devSandboxItem(r, env, ctx), dev: true },
  { method: "POST", pattern: /^\/dev\/fire-webhook$/, label: "/dev/fire-webhook", handler: (r, env) => devFireWebhook(r, env), dev: true },
];

async function health(env: Env): Promise<Response> {
  const db = await env.DB.prepare("SELECT 1 AS ok").first<number>("ok");
  return json({
    ok: db === 1,
    env: env.ENVIRONMENT,
    plaid_env: env.PLAID_ENV,
    version: env.CF_VERSION_METADATA?.id ?? "local",
    time: new Date().toISOString(),
  });
}

function toResponse(error: unknown, label: string): Response {
  if (error instanceof ApiError) return errorResponse(error);
  if (error instanceof PlaidError) {
    console.warn(JSON.stringify({ event: "plaid_error", route: label, code: error.code }));
    return errorResponse(new ApiError(502, "bank_error", itemErrorMessage(error)));
  }
  // Messages only; never request bodies, tokens, or financial data.
  console.error(JSON.stringify({ event: "unhandled_error", route: label, message: String((error as Error)?.message ?? error).slice(0, 300) }));
  return errorResponse(new ApiError(500, "internal", "Something went wrong on our side. Please try again."));
}

async function runCron(env: Env, scheduledTime: number): Promise<void> {
  const synced = await runScheduledSync(env);
  const now = Date.now();
  await env.DB.batch([
    env.DB.prepare("DELETE FROM sessions WHERE expires_at < ?1 OR revoked_at < ?2").bind(now, now - 7 * 86_400_000),
    env.DB.prepare("DELETE FROM link_sessions WHERE created_at < ?1").bind(now - 2 * 86_400_000),
  ]);
  // Once a day (the 09:00 UTC run): remove rows a background sync wrote while their account was being deleted.
  const time = new Date(scheduledTime);
  if (time.getUTCHours() === 9 && time.getUTCMinutes() < 10) {
    await env.DB.batch(
      PULL_TABLES.map((table) => env.DB.prepare(`DELETE FROM ${table.name} WHERE user_id NOT IN (SELECT id FROM users)`)),
    );
  }
  console.log(JSON.stringify({ event: "cron", synced }));
}

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const started = Date.now();
    const path = new URL(request.url).pathname.replace(/\/+$/, "") || "/";
    let label = "unknown";
    let response: Response;
    try {
      const route = routes.find((r) => r.method === request.method && r.pattern.test(path) && (!r.dev || devRoutesEnabled(env)));
      if (!route) throw new ApiError(404, "not_found", "Not found.");
      label = route.label;
      response = await route.handler(request, env, ctx, route.pattern.exec(path)!.slice(1));
    } catch (error) {
      response = toResponse(error, label);
    }
    console.log(JSON.stringify({ event: "request", method: request.method, route: label, status: response.status, ms: Date.now() - started }));
    return response;
  },

  async scheduled(controller, env, ctx): Promise<void> {
    ctx.waitUntil(runCron(env, controller.scheduledTime).catch((error) => console.error(JSON.stringify({ event: "cron_failed", message: String(error?.message ?? error) }))));
  },
} satisfies ExportedHandler<Env>;

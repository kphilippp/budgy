// Budgy relay server (Cloudflare Worker).
//
// Holds your Plaid secret and access tokens so they never live on your phone.
// The iPhone app talks only to this worker, authenticated with APP_TOKEN.
//
// Secrets (set with `wrangler secret put <NAME>`):
//   PLAID_CLIENT_ID, PLAID_SECRET, APP_TOKEN
// Vars (wrangler.toml): PLAID_ENV = "sandbox" | "production"
// KV namespace binding: ITEMS

const REDIRECT_URI = "budgy://plaid-complete";

export default {
  async fetch(request, env) {
    if (request.method !== "POST") return json({ error: "POST only" }, 405);

    // Say which setting is missing (never its value) so setup problems are easy to spot.
    const missing = ["APP_TOKEN", "PLAID_CLIENT_ID", "PLAID_SECRET"].filter((name) => !env[name]);
    if (missing.length) {
      return json({ error: `Relay setup: missing ${missing.join(", ")}. Add them as Secrets in Cloudflare (Settings → Variables and Secrets), then deploy.` }, 500);
    }

    const auth = (request.headers.get("Authorization") || "").trim();
    if (auth !== `Bearer ${env.APP_TOKEN.trim()}`) {
      return json({ error: "Unauthorized: the App token in Budgy doesn't match APP_TOKEN on the relay." }, 401);
    }

    const path = new URL(request.url).pathname;
    const body = await request.json().catch(() => ({}));

    try {
      switch (path) {
        case "/health": return json({ ok: true, env: env.PLAID_ENV });
        case "/link/create": return json(await createLink(env, body));
        case "/link/complete": return json(await completeLink(env, body));
        case "/accounts": return json(await getAccounts(env));
        case "/transactions/sync": return json(await syncTransactions(env, body));
        case "/items/remove": return json(await removeItem(env, body));
        default: return json({ error: "Not found" }, 404);
      }
    } catch (error) {
      return json({ error: error.message || String(error) }, 500);
    }
  },
};

// MARK: - Plaid helpers

function plaidHost(env) {
  return env.PLAID_ENV === "production" ? "https://production.plaid.com" : "https://sandbox.plaid.com";
}

async function plaid(env, endpoint, payload) {
  const response = await fetch(`${plaidHost(env)}${endpoint}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ client_id: env.PLAID_CLIENT_ID, secret: env.PLAID_SECRET, ...payload }),
  });
  const data = await response.json();
  if (!response.ok) {
    const message = data.error_message || data.error_code || `Plaid error ${response.status}`;
    const error = new Error(message);
    error.code = data.error_code;
    throw error;
  }
  return data;
}

async function listItems(env) {
  const items = [];
  let cursor;
  do {
    const page = await env.ITEMS.list({ prefix: "item:", cursor });
    for (const key of page.keys) {
      const value = await env.ITEMS.get(key.name, "json");
      if (value) items.push({ item_id: key.name.slice(5), ...value });
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  return items;
}

// MARK: - Link (Hosted Link flow)

async function createLink(env, { kind }) {
  const isInvestments = kind === "investments";
  const data = await plaid(env, "/link/token/create", {
    client_name: "Budgy",
    language: "en",
    country_codes: ["US"],
    user: { client_user_id: "budgy-owner" },
    products: isInvestments ? ["investments"] : ["transactions"],
    transactions: isInvestments ? undefined : { days_requested: 365 },
    // Plaid hosts the page (and any bank OAuth redirects) itself; it sends us back to the app when done.
    hosted_link: { completion_redirect_uri: REDIRECT_URI },
  });
  return { link_token: data.link_token, hosted_link_url: data.hosted_link_url, is_investments: isInvestments };
}

async function completeLink(env, { link_token, is_investments }) {
  const data = await plaid(env, "/link/token/get", { link_token });
  const added = [];
  for (const session of data.link_sessions || []) {
    const results = session.results?.item_add_results || [];
    for (const result of results) {
      const exchange = await plaid(env, "/item/public_token/exchange", { public_token: result.public_token });
      const institutionName = result.institution?.name || "Bank";
      await env.ITEMS.put(`item:${exchange.item_id}`, JSON.stringify({
        access_token: exchange.access_token,
        institution_name: institutionName,
        is_investments: !!is_investments,
      }));
      added.push({ item_id: exchange.item_id, institution_name: institutionName, is_investments: !!is_investments });
    }
  }
  return { items: added };
}

// MARK: - Data

async function getAccounts(env) {
  const items = await listItems(env);
  const accounts = [];
  const errors = [];
  for (const item of items) {
    try {
      const data = await plaid(env, "/accounts/get", { access_token: item.access_token });
      for (const account of data.accounts) {
        accounts.push({
          item_id: item.item_id,
          institution_name: item.institution_name,
          account_id: account.account_id,
          name: account.name,
          official_name: account.official_name,
          mask: account.mask,
          type: account.type,
          subtype: account.subtype,
          current: account.balances.current,
          available: account.balances.available,
          limit: account.balances.limit,
        });
      }
    } catch (error) {
      errors.push({ item_id: item.item_id, error: error.message, code: error.code });
    }
  }
  return { accounts, errors };
}

async function syncTransactions(env, { cursors = {} }) {
  const items = await listItems(env);
  const results = [];
  for (const item of items) {
    if (item.is_investments) continue;
    let cursor = cursors[item.item_id] || undefined;
    const added = [], modified = [], removed = [];
    try {
      let hasMore = true;
      let pages = 0;
      while (hasMore && pages < 20) {
        const data = await plaid(env, "/transactions/sync", { access_token: item.access_token, cursor, count: 500 });
        added.push(...data.added.map(slim));
        modified.push(...data.modified.map(slim));
        removed.push(...data.removed.map((r) => r.transaction_id));
        cursor = data.next_cursor;
        hasMore = data.has_more;
        pages += 1;
      }
      results.push({ item_id: item.item_id, added, modified, removed, next_cursor: cursor || "" });
    } catch (error) {
      results.push({ item_id: item.item_id, added: [], modified: [], removed: [], next_cursor: cursors[item.item_id] || "", error: error.message });
    }
  }
  return { items: results };
}

function slim(t) {
  return {
    transaction_id: t.transaction_id,
    account_id: t.account_id,
    amount: t.amount,
    date: t.date,
    name: t.name,
    merchant_name: t.merchant_name,
    pending: t.pending,
    category_primary: t.personal_finance_category?.primary || "",
    category_detailed: t.personal_finance_category?.detailed || "",
  };
}

async function removeItem(env, { item_id }) {
  const item = await env.ITEMS.get(`item:${item_id}`, "json");
  if (item) {
    // Removing the item stops Plaid's monthly billing for it.
    await plaid(env, "/item/remove", { access_token: item.access_token }).catch(() => {});
    await env.ITEMS.delete(`item:${item_id}`);
  }
  return { removed: true };
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });
}

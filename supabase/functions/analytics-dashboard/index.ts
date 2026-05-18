import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const BH_URL = "https://dawvgbopyemcayavcatd.supabase.co";
const BH_ANON = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRhd3ZnYm9weWVtY2F5YXZjYXRkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTU3MzAwOTEsImV4cCI6MjA3MTMwNjA5MX0.TuQV1G_JsJQRjLr76f8xX2HUjCig5FQa8R-YpsPyJiw";

const HTA_URL = Deno.env.get("SUPABASE_URL") || "https://llqhmywodxzstjlrulcw.supabase.co";
const HTA_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const HTA_ANON = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxscWhteXdvZHh6c3RqbHJ1bGN3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg5MTI1MTAsImV4cCI6MjA4NDQ4ODUxMH0.30Q5ZEbEat5uld9S24pjyJj6ULXUA6-d1b99nHJA9OM";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

// Verify user JWT and check admin role
async function verifyAdmin(token: string): Promise<{ ok: boolean; email?: string }> {
  const userRes = await fetch(`${HTA_URL}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${token}`, apikey: HTA_ANON },
  });
  if (!userRes.ok) return { ok: false };
  const user = await userRes.json();
  const userId = user.id;
  if (!userId) return { ok: false };

  const roleRes = await fetch(
    `${HTA_URL}/rest/v1/user_roles?user_id=eq.${userId}&role=eq.admin&select=id`,
    { headers: { apikey: HTA_KEY, Authorization: `Bearer ${HTA_KEY}` } }
  );
  if (!roleRes.ok) return { ok: false };
  const roles = await roleRes.json();
  return { ok: roles.length > 0, email: user.email };
}

async function fetchRpc(url: string, key: string, fn: string, body: Record<string, unknown> = {}) {
  const res = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: key, Authorization: `Bearer ${key}` },
    body: JSON.stringify(body),
  });
  if (!res.ok) return null;
  return await res.json();
}

function parseTimeWindow(req: Request): { from: string; to: string; includeAdmins: boolean } {
  const url = new URL(req.url);
  const fromParam = url.searchParams.get("from");
  const toParam = url.searchParams.get("to");
  const to = toParam ? new Date(toParam) : new Date();
  const from = fromParam ? new Date(fromParam) : new Date(to.getTime() - 30 * 24 * 60 * 60 * 1000);
  // 2026-05-14: include_admins (default false) flag exclusiva da aba AIrton.
  // Permite alternar entre visao oficial (sem admins) e debug interno enquanto o
  // produto esta em early adoption e a equipe domina o volume.
  const includeAdmins = url.searchParams.get("include_admins") === "true";
  return { from: from.toISOString(), to: to.toISOString(), includeAdmins };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS });
  }

  // Check for Authorization header
  const authHeader = req.headers.get("Authorization");
  const token = authHeader?.replace("Bearer ", "");

  if (!token) {
    return new Response(JSON.stringify({ error: "Token required. Use Authorization: Bearer <token>" }), {
      status: 401,
      headers: { ...CORS, "Content-Type": "application/json" },
    });
  }

  try {
    // Verify admin
    const { ok, email } = await verifyAdmin(token);
    if (!ok) {
      return new Response(JSON.stringify({ error: "access_denied", email: email || "unknown" }), {
        status: 403,
        headers: { ...CORS, "Content-Type": "application/json" },
      });
    }

    const { from, to, includeAdmins } = parseTimeWindow(req);

    // BH RPCs v2 aceitam janela temporal {p_from, p_to} -- reduz tempo da base
    // de ~3s (all-time) para ~1.2s em 7d / ~2.4s em 30d. v1 das RPCs sao mantidas
    // no banco para rollback (drop nao foi feito).
    const [bh, hta, bhGeo, htaGeo, bhNotif, bhExtras, bhUtm, bhIacoesDaily, bhOauth, bhAirton, bhAirtonTg, bhPoolV2] = await Promise.all([
      fetchRpc(BH_URL, BH_ANON, "get_analytics_data_v2", { p_from: from, p_to: to }),
      fetchRpc(HTA_URL, HTA_KEY, "get_analytics_data"),
      fetchRpc(BH_URL, BH_ANON, "get_geo_profiles"),
      fetchRpc(HTA_URL, HTA_KEY, "get_geo_profiles"),
      fetchRpc(BH_URL, BH_ANON, "get_notification_analytics"),
      fetchRpc(BH_URL, BH_ANON, "get_analytics_data_bh_extras_v2", { p_from: from, p_to: to }),
      fetchRpc(BH_URL, BH_ANON, "get_analytics_data_bh_utm_v2", { p_from: from, p_to: to }),
      fetchRpc(BH_URL, BH_ANON, "get_analytics_data_iacoes_daily_v2", { p_from: from, p_to: to }),
      fetchRpc(BH_URL, BH_ANON, "get_analytics_data_bh_oauth_v2", { p_from: from, p_to: to }),
      fetchRpc(BH_URL, BH_ANON, "get_analytics_data_airton_v2", { p_from: from, p_to: to, p_include_admins: includeAdmins }),
      // 2026-05-13: RPC complementar — funnel de linking + friction signals
      // (rate limit hits, tool limit exhausted). Eventos instrumentados em
      // companion-telegram-receiver, gemini-ai e IntegrationsNotificationsApp.
      fetchRpc(BH_URL, BH_ANON, "get_analytics_data_airton_telegram_v1", { p_from: from, p_to: to }),
      // 2026-05-18 Sprint TELEMETRY B1+B2+B3: pool V2 daily refill (substituiu
      // lifetime_feature_usage no produto em 14/05). 5 blocos: overview,
      // daily series, feature distribution, AIrton tool histogram, retention cohort.
      fetchRpc(BH_URL, BH_ANON, "get_analytics_data_bh_pool_v2", { p_from: from, p_to: to }),
    ]);

    // Merge BH data: base + notif + extras + utm + iacoes_daily + oauth + airton + airton_tg + pool_v2 (latest wins on conflict)
    const bhMerged = { ...(bh || {}), ...(bhNotif || {}), ...(bhExtras || {}), ...(bhUtm || {}), ...(bhIacoesDaily || {}), ...(bhOauth || {}), ...(bhAirton || {}), ...(bhAirtonTg || {}), ...(bhPoolV2 || {}) };

    return new Response(JSON.stringify({ admin: email, bh: bhMerged, hta, geo: { bh: bhGeo || [], hta: htaGeo || [] }, window: { from, to }, airton_include_admins: includeAdmins, ts: new Date().toISOString() }), {
      headers: {
        ...CORS,
        "Content-Type": "application/json",
        "Cache-Control": "private, max-age=300",
      },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: err.message }), {
      status: 500,
      headers: { ...CORS, "Content-Type": "application/json" },
    });
  }
});

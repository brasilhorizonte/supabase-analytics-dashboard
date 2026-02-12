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

async function fetchRpc(url: string, key: string, fn: string) {
  const res = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", apikey: key, Authorization: `Bearer ${key}` },
    body: "{}",
  });
  if (!res.ok) return null;
  return await res.json();
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

    // Fetch analytics data from both projects
    const [bh, hta] = await Promise.all([
      fetchRpc(BH_URL, BH_ANON, "get_analytics_data"),
      fetchRpc(HTA_URL, HTA_KEY, "get_analytics_data"),
    ]);

    return new Response(JSON.stringify({ admin: email, bh, hta, ts: new Date().toISOString() }), {
      headers: {
        ...CORS,
        "Content-Type": "application/json",
        "Cache-Control": "private, max-age=60",
      },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: err.message }), {
      status: 500,
      headers: { ...CORS, "Content-Type": "application/json" },
    });
  }
});

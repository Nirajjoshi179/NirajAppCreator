// Edge Function: verify-purchase
// Client sends { sku, purchaseToken } after a Google Play Billing purchase (with the user's Supabase JWT).
// We verify the token with the Google Play Developer API, then call iap_grant (service role).
// Required secrets (supabase secrets set ...):
//   PLAY_PACKAGE_NAME, GOOGLE_SERVICE_ACCOUNT_JSON  (service account with Play Console "View financial data" + "Manage orders")
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, content-type, apikey" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "content-type": "application/json" } });

function b64url(b: ArrayBuffer | string) {
  const s = typeof b === "string" ? btoa(b) : btoa(String.fromCharCode(...new Uint8Array(b)));
  return s.replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}
async function googleAccessToken(sa: { client_email: string; private_key: string }) {
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claim = b64url(JSON.stringify({ iss: sa.client_email, scope: "https://www.googleapis.com/auth/androidpublisher",
    aud: "https://oauth2.googleapis.com/token", iat: now, exp: now + 3600 }));
  const der = Uint8Array.from(atob(sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s/g, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${head}.${claim}`));
  const jwt = `${head}.${claim}.${b64url(sig)}`;
  const r = await fetch("https://oauth2.googleapis.com/token", { method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: jwt }) });
  return (await r.json()).access_token as string;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) return json({ error: "not_authenticated" }, 401);

    const { sku, purchaseToken } = await req.json();
    if (!sku || !purchaseToken) return json({ error: "bad_request" }, 400);

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: cfg } = await admin.from("remote_config").select("value").eq("key", "iap").single();
    const entry = (cfg?.value as any[]).find((e) => e.sku === sku);
    if (!entry) return json({ error: "unknown_sku" }, 400);

    const pkg = Deno.env.get("PLAY_PACKAGE_NAME")!;
    const token = await googleAccessToken(JSON.parse(Deno.env.get("GOOGLE_SERVICE_ACCOUNT_JSON")!));
    const sub = entry.type === "premium";
    const endpoint = sub
      ? `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${pkg}/purchases/subscriptions/${sku}/tokens/${purchaseToken}`
      : `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${pkg}/purchases/products/${sku}/tokens/${purchaseToken}`;
    const gp = await fetch(endpoint, { headers: { Authorization: `Bearer ${token}` } });
    if (!gp.ok) return json({ error: "play_verification_failed" }, 402);
    const p = await gp.json();

    // purchaseState 0 = purchased (one-time). Subscriptions: paymentState 1 = received, and not expired.
    const valid = sub ? (p.paymentState === 1 && Number(p.expiryTimeMillis) > Date.now()) : p.purchaseState === 0;
    if (!valid) return json({ error: "not_purchased" }, 402);

    const { data, error } = await admin.rpc("iap_grant", { p_user: user.id, p_sku: sku, p_token: purchaseToken, p_order: p.orderId ?? null });
    if (error) return json({ error: error.message }, error.message.includes("duplicate") ? 409 : 400);

    // Acknowledge/consume so Google doesn't auto-refund after 3 days
    const ackUrl = sub
      ? `${endpoint}:acknowledge`
      : (["coins", "piggy"].includes(entry.type) ? `${endpoint}:consume` : `${endpoint}:acknowledge`);
    await fetch(ackUrl, { method: "POST", headers: { Authorization: `Bearer ${token}`, "content-type": "application/json" }, body: "{}" });
    return json({ ok: true, grant: data });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

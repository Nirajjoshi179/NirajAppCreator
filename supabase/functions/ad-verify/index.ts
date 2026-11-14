// Edge Function: ad-verify
// Receives the AdMob rewarded-ad Server-Side Verification (SSV) callback (GET), verifies the
// ECDSA signature against Google's public keys, then marks the server-issued nonce as verified.
// Docs: https://developers.google.com/admob/android/ssv
// Set in AdMob: SSV callback URL = https://<project>.supabase.co/functions/v1/ad-verify
// Pass user_id and custom_data (= nonce from ad_request RPC) via ServerSideVerificationOptions in the app.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const KEYS_URL = "https://www.gstatic.com/admob/reward/verifier-keys.json";

function b64urlToBytes(s: string): Uint8Array {
  s = s.replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
}
function pemToDer(pem: string): Uint8Array {
  return Uint8Array.from(atob(pem.replace(/-----[^-]+-----/g, "").replace(/\s/g, "")), (c) => c.charCodeAt(0));
}
// DER ECDSA signature -> raw r||s (WebCrypto wants raw)
function derToRaw(der: Uint8Array): Uint8Array {
  let o = 2; if (der[1] & 0x80) o += der[1] & 0x7f;
  const rl = der[o + 1]; let r = der.slice(o + 2, o + 2 + rl); o += 2 + rl;
  const sl = der[o + 1]; let s = der.slice(o + 2, o + 2 + sl);
  const fix = (x: Uint8Array) => { while (x.length > 32 && x[0] === 0) x = x.slice(1); const out = new Uint8Array(32); out.set(x, 32 - x.length); return out; };
  const raw = new Uint8Array(64); raw.set(fix(r), 0); raw.set(fix(s), 32); return raw;
}

Deno.serve(async (req) => {
  try {
    const url = new URL(req.url);
    const query = url.search.slice(1);
    const sigIdx = query.indexOf("&signature=");
    if (sigIdx < 0) return new Response("bad request", { status: 400 });
    const signedContent = query.slice(0, sigIdx);               // everything before &signature=
    const params = url.searchParams;
    const signature = params.get("signature")!;
    const keyId = params.get("key_id")!;

    const keys = (await (await fetch(KEYS_URL)).json()).keys as { keyId: number; pem: string }[];
    const k = keys.find((x) => String(x.keyId) === keyId);
    if (!k) return new Response("unknown key", { status: 400 });

    const pub = await crypto.subtle.importKey("spki", pemToDer(k.pem), { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pub,
      derToRaw(b64urlToBytes(signature)), new TextEncoder().encode(signedContent));
    if (!ok) return new Response("invalid signature", { status: 403 });

    const nonce = params.get("custom_data");
    const userId = params.get("user_id");
    if (!nonce || !userId) return new Response("missing fields", { status: 400 });

    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);  // server-side only
    const { data, error } = await admin.rpc("ad_mark_verified", { p_nonce: nonce, p_user: userId });
    if (error) return new Response(error.message, { status: 500 });
    return new Response(data ? "verified" : "ignored", { status: 200 });
  } catch (e) {
    return new Response(String(e), { status: 500 });
  }
});

// Bergr push relay: holds the APNs key, hands devices a per-device secret.

const MAX_BODY = 4096;
const JWT_TTL_MS = 50 * 60 * 1000;
const PUSH_LIMIT_PER_HOUR = 120;
const REGISTER_LIMIT_PER_HOUR = 20;
const BUNDLE_RE = /^[A-Za-z0-9.-]{3,100}$/;
const TOKEN_RE = /^[0-9a-fA-F]{64,200}$/;

// Test hooks.
export const stats = { signs: 0 };
const jwtCache = new Map();
export function _resetCache() {
  jwtCache.clear();
  stats.signs = 0;
}

function json(status, obj) {
  if (status === 204) return new Response(null, { status });
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}

const err = (status, message) => json(status, { error: message });

async function sha256Hex(text) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function b64url(bytes) {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToDer(pem) {
  const body = pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  const bin = atob(body);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

async function apnsJwt(env, sandbox) {
  const name = sandbox ? "sandbox" : "production";
  const keyId = sandbox ? env.APNS_SANDBOX_KEY_ID : env.APNS_PRODUCTION_KEY_ID;
  const pem = sandbox ? env.APNS_SANDBOX_KEY : env.APNS_PRODUCTION_KEY;
  const team = env.APNS_TEAM_ID;
  if (!keyId || !pem || !team) return null;
  const cacheKey = `${name}:${team}:${keyId}`;
  const cached = jwtCache.get(cacheKey);
  const now = Date.now();
  if (cached && cached.exp > now) return cached.jwt;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(pem),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const enc = (o) => b64url(new TextEncoder().encode(JSON.stringify(o)));
  const signingInput =
    enc({ alg: "ES256", kid: keyId }) + "." + enc({ iss: team, iat: Math.floor(now / 1000) });
  // WebCrypto ECDSA already yields raw r||s.
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  stats.signs++;
  const jwt = signingInput + "." + b64url(new Uint8Array(sig));
  jwtCache.set(cacheKey, { jwt, exp: now + JWT_TTL_MS });
  return jwt;
}

// Returns parsed JSON object, or a Response on failure.
async function readJson(request) {
  const text = await request.text();
  if (new TextEncoder().encode(text).length > MAX_BODY) return err(413, "body too large");
  try {
    const v = JSON.parse(text);
    if (v && typeof v === "object" && !Array.isArray(v)) return v;
  } catch {}
  return err(400, "invalid json");
}

function bearer(request) {
  const m = /^Bearer\s+(\S+)$/i.exec(request.headers.get("authorization") || "");
  return m ? m[1] : null;
}

// Counts a hit; returns true if still within limit.
async function countHit(kv, key, limit) {
  const n = parseInt((await kv.get(key)) || "0", 10) || 0;
  if (n >= limit) return false;
  await kv.put(key, String(n + 1), { expirationTtl: 7200 });
  return true;
}

const hourBucket = () => Math.floor(Date.now() / 3600000);

async function register(request, env) {
  const declared = parseInt(request.headers.get("content-length") || "0", 10);
  if (declared > MAX_BODY) return err(413, "body too large");
  const body = await readJson(request);
  if (body instanceof Response) return body;
  const { token, bundle_id: bundleId, sandbox } = body;
  if (typeof token !== "string" || !TOKEN_RE.test(token)) return err(400, "invalid token");
  if (typeof bundleId !== "string" || !BUNDLE_RE.test(bundleId)) return err(400, "invalid bundle_id");
  if (typeof sandbox !== "boolean") return err(400, "invalid sandbox");
  if (env.ALLOWED_BUNDLE_IDS) {
    const allowed = env.ALLOWED_BUNDLE_IDS.split(",").map((s) => s.trim()).filter(Boolean);
    if (!allowed.includes(bundleId)) return err(403, "bundle_id not allowed");
  }
  // TODO(plus): verify App Attest and the Bergr Plus purchase
  const ip = request.headers.get("CF-Connecting-IP") || "unknown";
  const ipKey = `rl:ip:${await sha256Hex(ip)}:${hourBucket()}`;
  if (!(await countHit(env.REGISTRATIONS, ipKey, REGISTER_LIMIT_PER_HOUR))) {
    return err(429, "rate limited");
  }
  const raw = new Uint8Array(32);
  crypto.getRandomValues(raw);
  const secret = b64url(raw);
  await env.REGISTRATIONS.put(
    `reg:${await sha256Hex(secret)}`,
    JSON.stringify({ token, bundle_id: bundleId, sandbox, created: new Date().toISOString() }),
  );
  return json(200, { secret });
}

async function unregister(request, env) {
  const secret = bearer(request);
  if (!secret) return err(401, "unauthorized");
  const key = `reg:${await sha256Hex(secret)}`;
  if (!(await env.REGISTRATIONS.get(key))) return err(401, "unauthorized");
  await env.REGISTRATIONS.delete(key);
  return json(204);
}

const LIMITS = { title: 100, body: 400, address: 64, host: 100 };
const E_MAX = 3000;
const E_RE = /^[A-Za-z0-9+/]+={0,2}$/;

async function push(request, env) {
  const declared = parseInt(request.headers.get("content-length") || "0", 10);
  if (declared > MAX_BODY) return err(413, "body too large");
  const secret = bearer(request);
  if (!secret) return err(401, "unauthorized");
  const hash = await sha256Hex(secret);
  const regKey = `reg:${hash}`;
  const regText = await env.REGISTRATIONS.get(regKey);
  if (!regText) return err(401, "unauthorized");
  const reg = JSON.parse(regText);

  const body = await readJson(request);
  if (body instanceof Response) return body;
  // Either plain title+body, or `e`: an end-to-end encrypted blob the phone's extension opens.
  const encrypted = body.e !== undefined;
  for (const [field, max] of Object.entries(LIMITS)) {
    if (encrypted && (field === "title" || field === "body")) continue;
    if (typeof body[field] !== "string" || body[field].length > max) {
      return err(400, `invalid ${field}`);
    }
  }
  if (encrypted && (typeof body.e !== "string" || !body.e || body.e.length > E_MAX || !E_RE.test(body.e))) {
    return err(400, "invalid e");
  }
  if (!(await countHit(env.REGISTRATIONS, `rl:${hash}:${hourBucket()}`, PUSH_LIMIT_PER_HOUR))) {
    return err(429, "rate limited");
  }
  const envName = reg.sandbox ? "sandbox" : "production";
  let jwt;
  try {
    jwt = await apnsJwt(env, reg.sandbox);
  } catch (e) {
    console.error("jwt error", e && e.name);
    return err(503, `no key for ${envName}`);
  }
  if (!jwt) return err(503, `no key for ${envName}`);

  const host = reg.sandbox ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
  let res;
  try {
    res = await fetch(`${host}/3/device/${reg.token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": reg.bundle_id,
        "apns-push-type": "alert",
        "apns-collapse-id": body.address,
        "content-type": "application/json",
      },
      body: JSON.stringify(
        encrypted
          ? {
              aps: {
                alert: { title: "Bergr", body: "An agent needs you" },
                "mutable-content": 1,
                sound: "default",
                "thread-id": body.address,
              },
              e: body.e,
              address: body.address,
              host: body.host,
            }
          : {
              aps: {
                alert: { title: body.title, body: body.body },
                sound: "default",
                "thread-id": body.address,
              },
              address: body.address,
              host: body.host,
            },
      ),
    });
  } catch (e) {
    console.error("apns fetch failed", e && e.name);
    return err(502, "apns unreachable");
  }
  if (res.status === 200) return json(200, { ok: true });
  let reason = "unknown";
  try {
    reason = (await res.json()).reason || reason;
  } catch {}
  if ((res.status === 400 && reason === "BadDeviceToken") || res.status === 410) {
    await env.REGISTRATIONS.delete(regKey);
    return err(410, "unregistered");
  }
  console.error("apns error", res.status, reason);
  return err(502, reason);
}

export async function handle(request, env) {
  const { pathname } = new URL(request.url);
  const m = request.method;
  try {
    if (pathname === "/v1/register" && m === "POST") return await register(request, env);
    if (pathname === "/v1/register" && m === "DELETE") return await unregister(request, env);
    if (pathname === "/v1/push" && m === "POST") return await push(request, env);
  } catch (e) {
    console.error("internal error", e && e.name);
    return err(500, "internal error");
  }
  return err(404, "not found");
}

export default { fetch: handle };

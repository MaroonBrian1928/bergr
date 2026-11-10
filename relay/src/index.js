// Bergr push relay: holds the APNs key, hands devices a per-device secret.

const MAX_BODY = 4096;
const ACTIVITY_MAX_BODY = 16384; // POST /v1/activity may carry a seed of machine records
const JWT_TTL_MS = 50 * 60 * 1000;
const PUSH_LIMIT_PER_HOUR = 120;
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
async function readJson(request, max = MAX_BODY) {
  const text = await request.text();
  if (new TextEncoder().encode(text).length > max) return err(413, "body too large");
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

// ---- Per-device state: one Durable Object (SQLite-backed) per registration hash.
//
// The Worker authenticates by hashing the bearer secret and asking the DO. All hot state lives in
// the DO, so Live Activity state posts and pushes cost no KV operations. KV `reg:<hash>` stays as a
// dual-written copy (for rollback, and for lazily seeding registrations made before the DO existed).
//
// Storage uses the async key-value API (`ctx.storage.get/put/delete/deleteAll/list`), which a
// SQLite-backed DO also offers; it is trivial to fake in tests. Keys: `reg`, `la`, `gone` (tombstone
// after unregister) and `m:<machine id>` (one record per machine, holding the last push timestamp). Rate-limit buckets are in memory (lost when the DO is
// evicted, which only ever gives a device a fresh bucket). No timers, alarms, waitUntil or
// outbound fetches in here: the Worker does the APNs calls.

const MACHINE_STALE_MS = 15 * 60 * 1000;
const MAX_MACHINES = 20;
const ACTIVITY_TTL_MS = 12 * 3600 * 1000;
const ROW_MAX = 3;
const KINDS = new Set(["claude", "codex", "antigravity", "shell"]);
// Token buckets: capacity per hour, refilled continuously. Urgent state posts have their own.
const BUCKETS = { push: PUSH_LIMIT_PER_HOUR, state: 720, urgent: 60 };

const count = (v) => (Number.isInteger(v) && v >= 0 && v < 10000 ? v : 0);
const text = (v, max) => (typeof v === "string" ? v.slice(0, max) : "");

function cleanRows(rows) {
  if (!Array.isArray(rows)) return [];
  return rows.slice(0, ROW_MAX).filter((r) => r && typeof r === "object").map((r) => ({
    kind: KINDS.has(r.kind) ? r.kind : "shell",
    title: text(r.title, 60),
    status: text(r.status, 80),
    machine: text(r.machine, 40),
    needsYou: r.needsYou === true,
    host: text(r.host, 64),
    address: text(r.address, 64),
  }));
}

function cleanRecord(v, mode, at) {
  return {
    at,
    needsYou: count(v.needsYou), working: count(v.working), done: count(v.done),
    rows: mode === "full" ? cleanRows(v.rows) : [],
  };
}

/// The sum over the machines that posted lately: counts added, rows needs-you first.
export function mergeActivity(machines, mode, now = Date.now()) {
  let needsYou = 0, working = 0, done = 0;
  let rows = [];
  for (const m of Object.values(machines)) {
    if (!m || now - m.at > MACHINE_STALE_MS) continue;
    needsYou += m.needsYou; working += m.working; done += m.done;
    if (mode === "full") rows = rows.concat(m.rows || []);
  }
  rows.sort((a, b) => Number(b.needsYou) - Number(a.needsYou));
  return { needsYou, working, done, rows: rows.slice(0, ROW_MAX) };
}

export class Device {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    this.buckets = new Map();
  }

  async fetch(request) {
    const out = await this.run(await request.json());
    return new Response(JSON.stringify(out), { headers: { "content-type": "application/json" } });
  }

  take(name, now) {
    const cap = BUCKETS[name];
    let b = this.buckets.get(name);
    if (!b) this.buckets.set(name, (b = { tokens: cap, at: now }));
    b.tokens = Math.min(cap, b.tokens + ((now - b.at) * cap) / 3600000);
    b.at = now;
    if (b.tokens < 1) return false;
    b.tokens -= 1;
    return true;
  }

  async machines() {
    const out = Object.create(null); // machine ids are untrusted: "__proto__" must be a plain key
    for (const [k, v] of await this.ctx.storage.list({ prefix: "m:" })) out[k.slice(2)] = v;
    return out;
  }

  async dropMachines(except = Object.create(null)) {
    const keys = Object.keys(await this.machines()).filter((k) => !Object.hasOwn(except, k)).map((k) => "m:" + k);
    if (keys.length) await this.ctx.storage.delete(keys);
  }

  /// Delete everything, and leave a tombstone so the Worker doesn't re-seed from KV, which is
  /// eventually consistent and may still show the deleted `reg:` key for a while.
  async forget() {
    await this.ctx.storage.deleteAll();
    await this.ctx.storage.put("gone", true);
    this.buckets.clear();
    return { ok: true };
  }

  async clearActivity() {
    await this.dropMachines();
    await this.ctx.storage.delete("la");
  }

  async run(b) {
    const s = this.ctx.storage;
    const now = Date.now();
    if (b.op === "seed") {
      await s.put("reg", b.reg);
      return { ok: true };
    }
    if (b.op === "clear") return this.forget();
    const got = await s.get(["reg", "la", "gone"]);
    const reg = got.get("reg");
    if (!reg) return { unauth: true, gone: got.get("gone") === true }; // writes nothing
    let la = got.get("la");
    // Live Activities end after 8 h (12 h on the Lock Screen): an older registration is gone.
    if (la && now - (la.at ?? now) > ACTIVITY_TTL_MS) la = undefined;
    const regOut = { token: reg.token, bundle_id: reg.bundle_id, sandbox: reg.sandbox };
    const laOut = la ? { active: true, mode: la.mode, hide_after: la.hideAfter ?? 86400 } : { active: false };

    switch (b.op) {
      case "push":
        if (!this.take("push", now)) return { limited: true };
        return { reg: regOut, ...laOut };

      case "unregister":
        return this.forget();

      case "activity": {
        const mode = b.mode === "full" ? "full" : "counts";
        // Finished agents untouched for longer than this (seconds; 0: never) don't count: the phone's
        // setting, passed on to the helpers, which know when each agent last changed.
        const hideAfter = Math.max(0, Math.min(parseInt(b.hide_after ?? "86400", 10) || 0, 30 * 86400));
        const seed = Object.create(null);
        if (b.machines && typeof b.machines === "object" && !Array.isArray(b.machines)) {
          for (const [id, v] of Object.entries(b.machines).slice(0, MAX_MACHINES)) {
            const name = text(id, 100);
            if (name && v && typeof v === "object") seed[name] = cleanRecord(v, mode, now);
          }
        }
        // A new activity starts from the seed (or nothing: the machines' next posts fill it); the
        // same one registered again (Bergr relaunched in the background) keeps what the machines said.
        const same = la?.token === b.token;
        if (!same) await this.dropMachines(seed);
        const all = same ? await this.machines() : Object.create(null);
        Object.assign(all, seed);
        // At most MAX_MACHINES: stale ones go first, then the oldest.
        const drop = [];
        for (const [k, v] of Object.entries(all)) {
          if (now - v.at > MACHINE_STALE_MS) { drop.push(k); delete all[k]; }
        }
        const byAge = Object.keys(all).sort((x, y) => all[x].at - all[y].at);
        while (byAge.length > MAX_MACHINES) { const k = byAge.shift(); drop.push(k); delete all[k]; }
        const puts = { la: { token: b.token, mode, hideAfter, at: now } };
        for (const k of Object.keys(seed)) if (Object.hasOwn(all, k)) puts["m:" + k] = seed[k];
        await s.put(puts);
        if (drop.length) await s.delete(drop.map((k) => "m:" + k));
        return { ok: true, mode };
      }

      case "clearActivity":
        await this.clearActivity();
        return { ok: true };

      case "clearIfToken":
        // A newer registration (different token) must survive a 410 for the old one.
        if (la && la.token === b.token) {
          await this.clearActivity();
          return { cleared: true, active: false };
        }
        return { cleared: false, ...laOut };

      case "state": {
        if (!la) return { active: false };
        const machine = text(b.machine, 100);
        if (!machine) return { invalid: "invalid machine" };
        const all = await this.machines();
        // The push timestamp lives in the machine records (no separate row, one put per post).
        let maxTs = 0;
        for (const v of Object.values(all)) maxTs = Math.max(maxTs, v.ts || 0);
        const stale = [];
        for (const [k, v] of Object.entries(all)) {
          if (now - v.at > MACHINE_STALE_MS) { stale.push("m:" + k); delete all[k]; }
        }
        if (!Object.hasOwn(all, machine) && Object.keys(all).length >= MAX_MACHINES) {
          return { invalid: "too many machines" };
        }
        if (!this.take(b.urgent === true ? "urgent" : "state", now)) return { limited: true };
        const ts = Math.max(Math.floor(now / 1000), maxTs + 1);
        const rec = { ...cleanRecord(b, la.mode, now), ts };
        all[machine] = rec;
        await s.put({ ["m:" + machine]: rec });
        if (stale.length) await s.delete(stale);
        return { ...laOut, reg: regOut, token: la.token, state: mergeActivity(all, la.mode, now), ts };
      }
    }
    return { error: "bad op" };
  }
}

const deviceStub = (env, hash) => env.DEVICE.get(env.DEVICE.idFromName(hash));
async function send(stub, payload) {
  const res = await stub.fetch(new Request("https://device/", { method: "POST", body: JSON.stringify(payload) }));
  return res.json();
}

/// One DO call. If the DO doesn't know the device yet, read KV `reg:<hash>` once: if found, seed the
/// DO and repeat the call; if not, null (the caller answers 401, and nothing was written anywhere).
async function call(env, hash, payload) {
  const stub = deviceStub(env, hash);
  const out = await send(stub, payload);
  if (!out.unauth) return out;
  if (out.gone) return null; // deleted here; KV may still show it
  const regText = await env.REGISTRATIONS.get(`reg:${hash}`);
  if (!regText) return null;
  await send(stub, { op: "seed", reg: JSON.parse(regText) });
  const again = await send(stub, payload);
  return again.unauth ? null : again;
}

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
  if (env.REGISTER_LIMITER) {
    const ip = request.headers.get("CF-Connecting-IP") || "unknown";
    const { success } = await env.REGISTER_LIMITER.limit({ key: await sha256Hex(ip) });
    if (!success) return err(429, "rate limited");
  }
  const raw = new Uint8Array(32);
  crypto.getRandomValues(raw);
  const secret = b64url(raw);
  const hash = await sha256Hex(secret);
  const reg = { token, bundle_id: bundleId, sandbox, created: new Date().toISOString() };
  // Dual write: KV keeps the registration for rollback and for lazy seeding.
  await env.REGISTRATIONS.put(`reg:${hash}`, JSON.stringify(reg));
  await send(deviceStub(env, hash), { op: "seed", reg });
  return json(200, { secret });
}

async function unregister(request, env) {
  const secret = bearer(request);
  if (!secret) return err(401, "unauthorized");
  const hash = await sha256Hex(secret);
  const out = await call(env, hash, { op: "unregister" });
  if (!out) return err(401, "unauthorized");
  // The DO is empty now; deleting KV too keeps the lazy seed from resurrecting the registration.
  await env.REGISTRATIONS.delete(`reg:${hash}`);
  return json(204);
}

const LIMITS = { title: 100, body: 400, address: 64, host: 100 };
const E_MAX = 3000;
const E_RE = /^[A-Za-z0-9+/]+={0,2}$/;

async function apnsReason(res) {
  try {
    return (await res.json()).reason || "unknown";
  } catch {
    return "unknown";
  }
}

async function push(request, env) {
  const declared = parseInt(request.headers.get("content-length") || "0", 10);
  if (declared > MAX_BODY) return err(413, "body too large");
  const secret = bearer(request);
  if (!secret) return err(401, "unauthorized");
  const hash = await sha256Hex(secret);

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
  const d = await call(env, hash, { op: "push" });
  if (!d) return err(401, "unauthorized");
  if (d.limited) return err(429, "rate limited");
  const reg = d.reg;
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
  if (res.status === 200) {
    // Helpers learn about an activity from any alert.
    const out = { ok: true, active: d.active };
    if (d.active) { out.mode = d.mode; out.hide_after = d.hide_after; }
    return json(200, out);
  }
  const reason = await apnsReason(res);
  if ((res.status === 400 && reason === "BadDeviceToken") || res.status === 410) {
    await env.REGISTRATIONS.delete(`reg:${hash}`);
    await send(deviceStub(env, hash), { op: "clear" });
    return err(410, "unregistered");
  }
  console.error("apns error", res.status, reason);
  return err(502, reason);
}

// ---- Live Activity: updated by push (no location keep-alive on the phone).
//
// The phone registers its activity's push token with its device secret and says what the
// activity may show: "counts" (how many agents need you, work, are done: no names or text) or
// "full" (also the top agents' names and statuses). Each machine's helper posts its own summary;
// the Device DO keeps one record per machine (stale after 15 minutes: a machine gone quiet drops
// out), adds them up, and the Worker pushes the sum to the activity. In "counts" mode helpers are
// told so and send no names, and anything they send anyway is dropped.

async function authed(request, env, payload) {
  const hash = await sha256Hex(bearer(request));
  return { hash, out: await call(env, hash, payload) };
}

async function activityRegister(request, env) {
  const declared = parseInt(request.headers.get("content-length") || "0", 10);
  if (declared > ACTIVITY_MAX_BODY) return err(413, "body too large");
  if (!bearer(request)) return err(401, "unauthorized");
  const body = await readJson(request, ACTIVITY_MAX_BODY);
  if (body instanceof Response) return body;
  if (typeof body.token !== "string" || !TOKEN_RE.test(body.token)) return err(400, "invalid token");
  const a = await authed(request, env, {
    op: "activity", token: body.token, mode: body.mode, hide_after: body.hide_after, machines: body.machines,
  });
  if (!a.out) return err(401, "unauthorized");
  return json(200, a.out);
}

async function activityUnregister(request, env) {
  if (!bearer(request)) return err(401, "unauthorized");
  const a = await authed(request, env, { op: "clearActivity" });
  if (!a.out) return err(401, "unauthorized");
  return json(204);
}

async function activityState(request, env) {
  const declared = parseInt(request.headers.get("content-length") || "0", 10);
  if (declared > MAX_BODY) return err(413, "body too large");
  if (!bearer(request)) return err(401, "unauthorized");
  const body = await readJson(request);
  if (body instanceof Response) return body;
  const a = await authed(request, env, {
    op: "state", machine: body.machine, needsYou: body.needsYou, working: body.working,
    done: body.done, rows: body.rows, urgent: body.urgent === true,
  });
  const d = a.out;
  if (!d) return err(401, "unauthorized");
  // No activity on the phone: nothing to do, and the helper can stop posting until there is one.
  if (d.active === false) return json(200, { active: false });
  if (d.invalid) return err(400, d.invalid);
  if (d.limited) return err(429, "rate limited");

  const reg = d.reg;
  let jwt;
  try {
    jwt = await apnsJwt(env, reg.sandbox);
  } catch (e) {
    console.error("jwt error", e && e.name);
    jwt = null;
  }
  if (!jwt) return err(503, `no key for ${reg.sandbox ? "sandbox" : "production"}`);
  const host = reg.sandbox ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
  let res;
  try {
    res = await fetch(`${host}/3/device/${d.token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": `${reg.bundle_id}.push-type.liveactivity`,
        "apns-push-type": "liveactivity",
        // Someone newly needed: right away. Otherwise the low priority Apple doesn't budget.
        "apns-priority": body.urgent === true ? "10" : "5",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        // Strictly increasing per device, so APNs never drops a push as older than the last.
        aps: { timestamp: d.ts, event: "update", "content-state": d.state, "stale-date": d.ts + 3600 },
      }),
    });
  } catch (e) {
    console.error("apns fetch failed", e && e.name);
    return err(502, "apns unreachable");
  }
  if (res.status === 200) return json(200, { active: true, mode: d.mode, hide_after: d.hide_after });
  const reason = await apnsReason(res);
  if ((res.status === 400 && reason === "BadDeviceToken") || res.status === 410) {
    // The activity ended on the phone: forget it, unless a newer one registered meanwhile.
    const c = await send(deviceStub(env, a.hash), { op: "clearIfToken", token: d.token });
    if (c.cleared || !c.active) return json(200, { active: false });
    return json(200, { active: true, mode: c.mode, hide_after: c.hide_after });
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
    if (pathname === "/v1/activity" && m === "POST") return await activityRegister(request, env);
    if (pathname === "/v1/activity" && m === "DELETE") return await activityUnregister(request, env);
    if (pathname === "/v1/activity/state" && m === "POST") return await activityState(request, env);
  } catch (e) {
    console.error("internal error", e && e.name);
    return err(500, "internal error");
  }
  return err(404, "not found");
}

export default { fetch: handle };

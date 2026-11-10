import test from "node:test";
import assert from "node:assert/strict";
import { handle, stats, _resetCache, Device } from "../src/index.js";

class KV {
  constructor() { this.m = new Map(); this.ttls = []; this.ops = 0; this.writes = 0; }
  async get(k) { this.ops++; return this.m.has(k) ? this.m.get(k) : null; }
  async put(k, v, o = {}) { this.ops++; this.writes++; this.m.set(k, v); if (o.expirationTtl) this.ttls.push([k, o.expirationTtl]); }
  async delete(k) { this.ops++; this.writes++; this.m.delete(k); }
}

// Fake DO storage: the async key-value API, values cloned like the real thing.
class Storage {
  constructor() { this.m = new Map(); }
  async get(k) {
    if (Array.isArray(k)) return new Map(k.filter((x) => this.m.has(x)).map((x) => [x, structuredClone(this.m.get(x))]));
    return this.m.has(k) ? structuredClone(this.m.get(k)) : undefined;
  }
  async put(k, v) {
    if (typeof k === "string") this.m.set(k, structuredClone(v));
    else for (const [a, b] of Object.entries(k)) this.m.set(a, structuredClone(b));
  }
  async delete(k) { for (const x of Array.isArray(k) ? k : [k]) this.m.delete(x); }
  async deleteAll() { this.m.clear(); }
  async list({ prefix = "" } = {}) {
    return new Map([...this.m].filter(([k]) => k.startsWith(prefix)).sort().map(([k, v]) => [k, structuredClone(v)]));
  }
}

// Fake namespace: one Device per name, calls on one instance run one at a time (input gates).
class DONamespace {
  constructor() { this.devices = new Map(); }
  idFromName(name) { return name; }
  get(id) {
    if (!this.devices.has(id)) {
      const storage = new Storage();
      this.devices.set(id, { storage, device: new Device({ storage }, {}), tail: Promise.resolve() });
    }
    const inst = this.devices.get(id);
    return {
      fetch: (request) => {
        const run = inst.tail.then(() => inst.device.fetch(request));
        inst.tail = run.catch(() => {});
        return run;
      },
    };
  }
  keys() { return [...this.devices.values()].flatMap((i) => [...i.storage.m.keys()]); }
  only() { return [...this.devices.values()][0].storage.m; }
}

const realFetch = globalThis.fetch;
let calls;
let apnsResponse;
test.beforeEach(() => {
  _resetCache();
  calls = [];
  apnsResponse = () => new Response("", { status: 200 });
  globalThis.fetch = async (url, init) => { calls.push({ url, init }); return apnsResponse(); };
});
test.after(() => { globalThis.fetch = realFetch; });

async function makeEnv(extra = {}) {
  const { publicKey, privateKey } = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = Buffer.from(await crypto.subtle.exportKey("pkcs8", privateKey)).toString("base64");
  const pem = `-----BEGIN PRIVATE KEY-----\n${der.match(/.{1,64}/g).join("\n")}\n-----END PRIVATE KEY-----\n`;
  return {
    publicKey,
    env: {
      REGISTRATIONS: new KV(),
      DEVICE: new DONamespace(),
      APNS_TEAM_ID: "TEAM123456",
      APNS_SANDBOX_KEY_ID: "SBKEY",
      APNS_SANDBOX_KEY: pem,
      APNS_PRODUCTION_KEY_ID: "PRKEY",
      APNS_PRODUCTION_KEY: pem,
      ...extra,
    },
  };
}

const TOKEN = "ab".repeat(32);
const req = (path, method, body, headers = {}) =>
  new Request("https://relay.test" + path, {
    method,
    headers: { "CF-Connecting-IP": "1.2.3.4", ...headers },
    body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
  });
const reg = (env, sandbox = true, bundle = "app.bergr") =>
  handle(req("/v1/register", "POST", { token: TOKEN, bundle_id: bundle, sandbox }), env);
const doPush = (env, secret, extra = {}) =>
  handle(req("/v1/push", "POST", { title: "T", body: "B", address: "addr1", host: "h", ...extra }, { authorization: `Bearer ${secret}` }), env);

test("register then push to sandbox with valid JWT", async () => {
  const { env, publicKey } = await makeEnv();
  const r = await reg(env);
  assert.equal(r.status, 200);
  const { secret } = await r.json();
  assert.equal(secret.length, 43);
  assert.ok(![...env.REGISTRATIONS.m.values()].some((v) => v.includes(secret)));
  const p = await doPush(env, secret);
  assert.equal(p.status, 200);
  assert.deepEqual(await p.json(), { ok: true, active: false });
  assert.equal(calls.length, 1);
  const { url, init } = calls[0];
  assert.equal(url, `https://api.sandbox.push.apple.com/3/device/${TOKEN}`);
  assert.equal(init.headers["apns-topic"], "app.bergr");
  assert.equal(init.headers["apns-push-type"], "alert");
  assert.equal(init.headers["apns-collapse-id"], "addr1");
  assert.deepEqual(JSON.parse(init.body), {
    aps: { alert: { title: "T", body: "B" }, sound: "default", "thread-id": "addr1" },
    address: "addr1",
    host: "h",
  });
  const jwt = init.headers.authorization.replace(/^bearer /, "");
  const [h, c, s] = jwt.split(".");
  assert.deepEqual(JSON.parse(Buffer.from(h, "base64url")), { alg: "ES256", kid: "SBKEY" });
  assert.equal(JSON.parse(Buffer.from(c, "base64url")).iss, "TEAM123456");
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, Buffer.from(s, "base64url"), new TextEncoder().encode(`${h}.${c}`));
  assert.ok(ok);
});

test("production host when sandbox false", async () => {
  const { env } = await makeEnv();
  const { secret } = await (await reg(env, false)).json();
  await doPush(env, secret);
  assert.equal(calls[0].url, `https://api.push.apple.com/3/device/${TOKEN}`);
});

test("bad secret is 401", async () => {
  const { env } = await makeEnv();
  assert.equal((await doPush(env, "nope")).status, 401);
  assert.equal(calls.length, 0);
});

test("APNs 410 deletes registration", async () => {
  const { env } = await makeEnv();
  const { secret } = await (await reg(env)).json();
  apnsResponse = () => new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410 });
  const p = await doPush(env, secret);
  assert.equal(p.status, 410);
  assert.deepEqual(await p.json(), { error: "unregistered" });
  assert.equal((await doPush(env, secret)).status, 401);
});

test("other APNs error is 502 with reason", async () => {
  const { env } = await makeEnv();
  const { secret } = await (await reg(env)).json();
  apnsResponse = () => new Response(JSON.stringify({ reason: "TooManyRequests" }), { status: 429 });
  const p = await doPush(env, secret);
  assert.equal(p.status, 502);
  assert.deepEqual(await p.json(), { error: "TooManyRequests" });
});

test("rate limit 429 after 120", async () => {
  const { env } = await makeEnv();
  const { secret } = await (await reg(env)).json();
  for (let i = 0; i < 120; i++) assert.equal((await doPush(env, secret)).status, 200);
  assert.equal((await doPush(env, secret)).status, 429);
  assert.equal(env.REGISTRATIONS.ttls.length, 0);
});

test("registration rate limit binding, keyed by hashed IP; absent binding allows", async () => {
  const keys = [];
  let n = 0;
  const { env } = await makeEnv({ REGISTER_LIMITER: { limit: async ({ key }) => { keys.push(key); return { success: ++n <= 5 }; } } });
  for (let i = 0; i < 5; i++) assert.equal((await reg(env)).status, 200);
  assert.equal((await reg(env)).status, 429);
  assert.match(keys[0], /^[0-9a-f]{64}$/);
  const { env: open } = await makeEnv();
  for (let i = 0; i < 30; i++) assert.equal((await reg(open)).status, 200);
});

test("oversize body 413", async () => {
  const { env } = await makeEnv();
  const r = await handle(req("/v1/register", "POST", "x".repeat(5000)), env);
  assert.equal(r.status, 413);
  const { secret } = await (await reg(env)).json();
  const p = await handle(req("/v1/push", "POST", "x".repeat(5000), { authorization: `Bearer ${secret}` }), env);
  assert.equal(p.status, 413);
});

test("missing key env is 503", async () => {
  const { env } = await makeEnv({ APNS_PRODUCTION_KEY: undefined });
  const { secret } = await (await reg(env, false)).json();
  const p = await doPush(env, secret);
  assert.equal(p.status, 503);
  assert.deepEqual(await p.json(), { error: "no key for production" });
});

test("ALLOWED_BUNDLE_IDS gives 403", async () => {
  const { env } = await makeEnv({ ALLOWED_BUNDLE_IDS: "app.bergr, other.app" });
  assert.equal((await reg(env, true, "evil.app")).status, 403);
  assert.equal((await reg(env, true, "other.app")).status, 200);
});

test("JWT cached across pushes", async () => {
  const { env } = await makeEnv();
  const { secret } = await (await reg(env)).json();
  await doPush(env, secret);
  await doPush(env, secret);
  assert.equal(stats.signs, 1);
  assert.equal(calls[0].init.headers.authorization, calls[1].init.headers.authorization);
});

test("delete registration and unknown route", async () => {
  const { env } = await makeEnv();
  const { secret } = await (await reg(env)).json();
  const d = await handle(req("/v1/register", "DELETE", undefined, { authorization: `Bearer ${secret}` }), env);
  assert.equal(d.status, 204);
  assert.equal((await doPush(env, secret)).status, 401);
  assert.equal((await handle(req("/nope", "GET"), env)).status, 404);
});

test("encrypted push forwards opaque blob with placeholder alert", async () => {
  const { env } = await makeEnv();
  const { secret } = await (await reg(env)).json();
  const e = "QUJD".repeat(100);
  const p = await handle(req("/v1/push", "POST", { e, address: "addr1", host: "h" }, { authorization: `Bearer ${secret}` }), env);
  assert.equal(p.status, 200);
  assert.deepEqual(JSON.parse(calls[0].init.body), {
    aps: { alert: { title: "Bergr", body: "An agent needs you" }, "mutable-content": 1, sound: "default", "thread-id": "addr1" },
    e,
    address: "addr1",
    host: "h",
  });
});

test("encrypted push rejects oversize or non-base64 e", async () => {
  const { env } = await makeEnv();
  const { secret } = await (await reg(env)).json();
  const send = (e) => handle(req("/v1/push", "POST", { e, address: "a", host: "h" }, { authorization: `Bearer ${secret}` }), env);
  assert.equal((await send("A".repeat(3000))).status, 200);
  assert.equal((await send("A".repeat(3001))).status, 400);
  assert.equal((await send("not base64!")).status, 400);
  assert.equal((await send(5)).status, 400);
  assert.equal(calls.length, 1);
});

// ---- Live Activity

const LA_TOKEN = "cd".repeat(40);
const auth = (secret) => ({ authorization: `Bearer ${secret}` });
async function withActivity(env, mode = "counts") {
  const { secret } = await (await reg(env)).json();
  const r = await handle(req("/v1/activity", "POST", { token: LA_TOKEN, mode }, auth(secret)), env);
  assert.equal(r.status, 200);
  return secret;
}
const post = (env, secret, body) => handle(req("/v1/activity/state", "POST", body, auth(secret)), env);
const sentState = (call) => JSON.parse(call.init.body).aps["content-state"];

test("activity state without an activity is inactive and sends nothing", async () => {
  const { env } = await makeEnv();
  const { secret } = await (await reg(env)).json();
  const r = await post(env, secret, { machine: "m1", needsYou: 1, working: 0, done: 0 });
  assert.deepEqual(await r.json(), { active: false });
  assert.equal(calls.length, 0);
});

test("counts mode sums machines and drops rows", async () => {
  const { env } = await makeEnv();
  const secret = await withActivity(env, "counts");
  await post(env, secret, { machine: "m1", needsYou: 1, working: 2, done: 0, rows: [{ title: "secret project" }] });
  const r = await post(env, secret, { machine: "m2", needsYou: 0, working: 1, done: 3 });
  assert.deepEqual(await r.json(), { active: true, mode: "counts", hide_after: 86400 });
  const last = calls.at(-1);
  assert.equal(last.url, `https://api.sandbox.push.apple.com/3/device/${LA_TOKEN}`);
  assert.equal(last.init.headers["apns-push-type"], "liveactivity");
  assert.equal(last.init.headers["apns-topic"], "app.bergr.push-type.liveactivity");
  assert.deepEqual(sentState(last), { needsYou: 1, working: 3, done: 3, rows: [] });
  assert.ok(![...env.DEVICE.only().values()].some((v) => JSON.stringify(v).includes("secret project")));
});

test("full mode keeps rows, needs-you first, at most 3", async () => {
  const { env } = await makeEnv();
  const secret = await withActivity(env, "full");
  const row = (title, needsYou) => ({ kind: "claude", title, status: "s", machine: "m", needsYou, host: "h", address: "t1" });
  await post(env, secret, { machine: "m1", needsYou: 0, working: 2, done: 0, rows: [row("a", false), row("b", false)] });
  await post(env, secret, { machine: "m2", needsYou: 1, working: 1, done: 0, rows: [row("c", true), row("d", false)] });
  const state = sentState(calls.at(-1));
  assert.equal(state.rows.length, 3);
  assert.equal(state.rows[0].title, "c");
  assert.equal(state.needsYou, 1);
});

test("stale machines drop out of the sum", async () => {
  const { mergeActivity } = await import("../src/index.js");
  const now = 10_000_000;
  const merged = mergeActivity({ a: { at: now, needsYou: 1, working: 0, done: 0 }, b: { at: now - 16 * 60 * 1000, needsYou: 5, working: 5, done: 5 } }, "counts", now);
  assert.deepEqual(merged, { needsYou: 1, working: 0, done: 0, rows: [] });
});

test("an ended activity (410) is forgotten", async () => {
  const { env } = await makeEnv();
  const secret = await withActivity(env);
  apnsResponse = () => new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410 });
  const r = await post(env, secret, { machine: "m1", needsYou: 0, working: 1, done: 0 });
  assert.deepEqual(await r.json(), { active: false });
  assert.ok(!env.DEVICE.keys().includes("la"));
  assert.ok(!env.DEVICE.keys().some((k) => k.startsWith("m:")));
});

test("urgent posts go at priority 10, others at 5", async () => {
  const { env } = await makeEnv();
  const secret = await withActivity(env);
  await post(env, secret, { machine: "m1", needsYou: 1, working: 0, done: 0, urgent: true });
  assert.equal(calls.at(-1).init.headers["apns-priority"], "10");
  await post(env, secret, { machine: "m1", needsYou: 0, working: 1, done: 0 });
  assert.equal(calls.at(-1).init.headers["apns-priority"], "5");
});

test("activity endpoints need the device secret", async () => {
  const { env } = await makeEnv();
  const r = await handle(req("/v1/activity", "POST", { token: LA_TOKEN }, auth("nope")), env);
  assert.equal(r.status, 401);
});

test("the phone's hide-after setting is handed to the helpers", async () => {
  const { env } = await makeEnv();
  const { secret } = await (await reg(env)).json();
  await handle(req("/v1/activity", "POST", { token: LA_TOKEN, mode: "counts", hide_after: "3600" }, auth(secret)), env);
  const r = await post(env, secret, { machine: "m1", needsYou: 0, working: 1, done: 0 });
  assert.equal((await r.json()).hide_after, 3600);
});

test("the same activity registered again keeps the machines' counts", async () => {
  const { env } = await makeEnv();
  const secret = await withActivity(env);
  await post(env, secret, { machine: "m1", needsYou: 0, working: 2, done: 0 });
  await handle(req("/v1/activity", "POST", { token: LA_TOKEN, mode: "counts" }, auth(secret)), env);
  assert.ok(env.DEVICE.keys().some((k) => k.startsWith("m:")));
  await handle(req("/v1/activity", "POST", { token: "ef".repeat(40), mode: "counts" }, auth(secret)), env);
  assert.ok(!env.DEVICE.keys().some((k) => k.startsWith("m:")));
});

// ---- Durable Object state

const activity = (env, secret, body) => handle(req("/v1/activity", "POST", { token: LA_TOKEN, mode: "counts", ...body }, auth(secret)), env);
const row = (title, needsYou) => ({ kind: "claude", title, status: "s", machine: "m", needsYou, host: "h", address: "t1" });
const machineKeys = (env) => env.DEVICE.keys().filter((k) => k.startsWith("m:")).sort();

test("state posts and pushes cost zero KV operations once the DO is seeded", async () => {
  const { env } = await makeEnv();
  const secret = await withActivity(env);
  env.REGISTRATIONS.ops = 0;
  for (let i = 0; i < 3; i++) assert.equal((await post(env, secret, { machine: "m1", needsYou: 0, working: i, done: 0 })).status, 200);
  assert.equal((await doPush(env, secret)).status, 200);
  assert.equal((await activity(env, secret, {})).status, 200);
  assert.equal(env.REGISTRATIONS.ops, 0);
});

test("two machines posting back to back both appear in the merged state", async () => {
  const { env } = await makeEnv();
  const secret = await withActivity(env);
  await Promise.all([
    post(env, secret, { machine: "m1", needsYou: 1, working: 0, done: 0 }),
    post(env, secret, { machine: "m2", needsYou: 0, working: 2, done: 0 }),
  ]);
  const last = calls.reduce((a, b) => (JSON.parse(a.init.body).aps.timestamp > JSON.parse(b.init.body).aps.timestamp ? a : b));
  assert.deepEqual(sentState(last), { needsYou: 1, working: 2, done: 0, rows: [] });
});

test("a seed in POST /v1/activity makes the first merged push include all seeded machines", async () => {
  const { env } = await makeEnv();
  const { secret } = await (await reg(env)).json();
  const machines = { a: { needsYou: 1, working: 0, done: 0 }, b: { needsYou: 0, working: 2, done: 1 }, c: { needsYou: 0, working: 1, done: 0 } };
  assert.equal((await activity(env, secret, { machines })).status, 200);
  await post(env, secret, { machine: "d", needsYou: 0, working: 0, done: 5 });
  assert.deepEqual(sentState(calls.at(-1)), { needsYou: 1, working: 3, done: 6, rows: [] });
});

test("seed rows are kept in full mode only, and machines are capped at 20", async () => {
  const { env } = await makeEnv();
  const { secret } = await (await reg(env)).json();
  const machines = {};
  for (let i = 0; i < 30; i++) machines["m" + i] = { needsYou: 0, working: 1, done: 0, rows: [row("t" + i, false)] };
  await activity(env, secret, { mode: "full", machines });
  await post(env, secret, { machine: "m0", needsYou: 0, working: 1, done: 0 });
  assert.equal(sentState(calls.at(-1)).working, 20);
  assert.equal(sentState(calls.at(-1)).rows.length, 3);
  const { env: e2 } = await makeEnv();
  const { secret: s2 } = await (await reg(e2)).json();
  await activity(e2, s2, { mode: "counts", machines: { a: { working: 1, rows: [row("x", false)] } } });
  assert.deepEqual(e2.DEVICE.only().get("m:a").rows, []);
});

test("same token re-registered keeps machine records, a new token replaces them", async () => {
  const { env } = await makeEnv();
  const secret = await withActivity(env);
  await post(env, secret, { machine: "m1", needsYou: 0, working: 2, done: 0 });
  await activity(env, secret, { machines: { m2: { working: 1 } } });
  assert.deepEqual(machineKeys(env), ["m:m1", "m:m2"]);
  await activity(env, secret, { token: "ef".repeat(40), machines: { m3: { needsYou: 1 } } });
  assert.deepEqual(machineKeys(env), ["m:m3"]);
  await activity(env, secret, { token: "12".repeat(40) });
  assert.deepEqual(machineKeys(env), []);
});

test("a 410 for a stale activity token does not clear a newer activity", async () => {
  const { env } = await makeEnv();
  const secret = await withActivity(env);
  const NEW = "ef".repeat(40);
  apnsResponse = async () => {
    await activity(env, secret, { token: NEW, mode: "full", machines: { m9: { working: 4 } } });
    return new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410 });
  };
  const r = await post(env, secret, { machine: "m1", needsYou: 0, working: 1, done: 0 });
  assert.deepEqual(await r.json(), { active: true, mode: "full", hide_after: 86400 });
  assert.equal(env.DEVICE.only().get("la").token, NEW);
  assert.ok(env.DEVICE.keys().includes("m:m9"));
});

test("DELETE /v1/register is not resurrected from KV", async () => {
  const { env } = await makeEnv();
  const { secret } = await (await reg(env)).json();
  assert.equal((await handle(req("/v1/register", "DELETE", undefined, auth(secret)), env)).status, 204);
  assert.deepEqual(env.DEVICE.keys(), ["gone"]);
  assert.equal((await doPush(env, secret)).status, 401);
  assert.equal((await post(env, secret, { machine: "m", working: 1 })).status, 401);
  assert.deepEqual(env.DEVICE.keys(), ["gone"]);
  assert.equal(calls.length, 0);
});

test("lazy seed: a KV-only registration is moved into the DO; an unknown secret writes nothing", async () => {
  const { env } = await makeEnv();
  const { secret } = await (await reg(env)).json();
  env.DEVICE = new DONamespace(); // as before the migration
  assert.equal(env.DEVICE.keys().length, 0);
  assert.equal((await doPush(env, secret)).status, 200);
  assert.ok(env.DEVICE.keys().includes("reg"));
  env.REGISTRATIONS.ops = 0;
  assert.equal((await doPush(env, secret)).status, 200);
  assert.equal(env.REGISTRATIONS.ops, 0);

  const { env: e2 } = await makeEnv();
  assert.equal((await doPush(e2, "nope")).status, 401);
  assert.equal((await post(e2, "nope", { machine: "m" })).status, 401);
  assert.equal(e2.DEVICE.keys().length, 0);
  assert.equal(e2.REGISTRATIONS.writes, 0);
});

test("ordinary state bucket gives 429 when exhausted while an urgent post still passes; urgent has its own limit", async () => {
  const { env } = await makeEnv();
  const secret = await withActivity(env);
  for (let i = 0; i < 720; i++) assert.equal((await post(env, secret, { machine: "m1", working: 1 })).status, 200);
  assert.equal((await post(env, secret, { machine: "m1", working: 1 })).status, 429);
  for (let i = 0; i < 60; i++) assert.equal((await post(env, secret, { machine: "m1", working: 1, urgent: true })).status, 200);
  assert.equal((await post(env, secret, { machine: "m1", working: 1, urgent: true })).status, 429);
  assert.equal((await post(env, secret, { machine: "m1", working: 1 })).status, 429);
});

test("push timestamps strictly increase within the same second", async () => {
  const { env } = await makeEnv();
  const secret = await withActivity(env);
  for (let i = 0; i < 5; i++) await post(env, secret, { machine: "m1", working: i });
  const ts = calls.map((c) => JSON.parse(c.init.body).aps.timestamp);
  assert.equal(ts.length, 5);
  for (let i = 1; i < ts.length; i++) assert.ok(ts[i] > ts[i - 1]);
});

test("/v1/push reply carries active, mode and hide_after", async () => {
  const { env } = await makeEnv();
  const { secret } = await (await reg(env)).json();
  assert.deepEqual(await (await doPush(env, secret)).json(), { ok: true, active: false });
  await activity(env, secret, { mode: "full", hide_after: 60 });
  assert.deepEqual(await (await doPush(env, secret)).json(), { ok: true, active: true, mode: "full", hide_after: 60 });
});

test("DELETE /v1/activity clears the activity and the machines", async () => {
  const { env } = await makeEnv();
  const secret = await withActivity(env);
  await post(env, secret, { machine: "m1", working: 1 });
  assert.equal((await handle(req("/v1/activity", "DELETE", undefined, auth(secret)), env)).status, 204);
  assert.ok(!env.DEVICE.keys().includes("la"));
  assert.deepEqual(machineKeys(env), []);
  assert.deepEqual(await (await post(env, secret, { machine: "m1", working: 1 })).json(), { active: false });
});

test("a stale KV copy of a deleted registration is not resurrected (eventual consistency)", async () => {
  for (const how of ["delete", "410"]) {
    const { env } = await makeEnv();
    const { secret } = await (await reg(env)).json();
    const kvKey = [...env.REGISTRATIONS.m.keys()][0];
    const kvValue = env.REGISTRATIONS.m.get(kvKey);
    if (how === "delete") await handle(req("/v1/register", "DELETE", undefined, auth(secret)), env);
    else {
      apnsResponse = () => new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410 });
      await doPush(env, secret);
    }
    env.REGISTRATIONS.m.set(kvKey, kvValue); // KV still shows it
    assert.equal((await doPush(env, secret)).status, 401);
  }
});

test("an activity older than 12 h is treated as absent, with no writes", async () => {
  const { env } = await makeEnv();
  const secret = await withActivity(env);
  const realNow = Date.now;
  try {
    Date.now = () => realNow() + 12 * 3600 * 1000 + 1000;
    const before = JSON.stringify([...env.DEVICE.only()]);
    const n = calls.length;
    assert.deepEqual(await (await post(env, secret, { machine: "m1", working: 1 })).json(), { active: false });
    assert.equal(calls.length, n);
    assert.equal(JSON.stringify([...env.DEVICE.only()]), before);
    assert.deepEqual(await (await doPush(env, secret)).json(), { ok: true, active: false });
  } finally { Date.now = realNow; }
});

test("machine ids like __proto__ and constructor are plain machines", async () => {
  const { env } = await makeEnv();
  const { secret } = await (await reg(env)).json();
  await handle(req("/v1/activity", "POST", `{"token":"${LA_TOKEN}","mode":"counts","machines":{"__proto__":{"working":2},"constructor":{"needsYou":1}}}`, auth(secret)), env);
  await post(env, secret, { machine: "__proto__", working: 3 });
  await post(env, secret, { machine: "toString", done: 1 });
  assert.deepEqual(machineKeys(env), ["m:__proto__", "m:constructor", "m:toString"]);
  assert.deepEqual(sentState(calls.at(-1)), { needsYou: 1, working: 3, done: 1, rows: [] });
});

test("re-registering the same token caps merged machines at 20, oldest first", async () => {
  const { env } = await makeEnv();
  const secret = await withActivity(env);
  for (let i = 0; i < 15; i++) await post(env, secret, { machine: "old" + i, working: 1 });
  const seed = {};
  for (let i = 0; i < 15; i++) seed["new" + i] = { working: 1 };
  await activity(env, secret, { machines: seed });
  assert.equal(machineKeys(env).length, 20);
  assert.ok(machineKeys(env).includes("m:new14"));
  assert.ok(!machineKeys(env).includes("m:old0"));
});

test("one storage put per state post, and no separate timestamp row", async () => {
  const { env } = await makeEnv();
  const secret = await withActivity(env);
  const storage = [...env.DEVICE.devices.values()][0].storage;
  let puts = 0;
  const put = storage.put.bind(storage);
  storage.put = async (...a) => { puts++; return put(...a); };
  await post(env, secret, { machine: "m1", working: 1 });
  await post(env, secret, { machine: "m2", working: 1 });
  await post(env, secret, { machine: "m1", working: 2 });
  assert.equal(puts, 3);
  assert.ok(!env.DEVICE.keys().includes("lastTs"));
  const ts = calls.map((c) => JSON.parse(c.init.body).aps.timestamp);
  assert.ok(ts[0] < ts[1] && ts[1] < ts[2]);
});

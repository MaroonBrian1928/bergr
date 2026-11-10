import test from "node:test";
import assert from "node:assert/strict";
import { handle, stats, _resetCache } from "../src/index.js";

class KV {
  constructor() { this.m = new Map(); this.ttls = []; }
  async get(k) { return this.m.has(k) ? this.m.get(k) : null; }
  async put(k, v, o = {}) { this.m.set(k, v); if (o.expirationTtl) this.ttls.push([k, o.expirationTtl]); }
  async delete(k) { this.m.delete(k); }
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
  assert.deepEqual(await p.json(), { ok: true });
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
  assert.ok(env.REGISTRATIONS.ttls.some(([k, t]) => k.startsWith("rl:") && t === 7200));
});

test("registration rate limit per IP", async () => {
  const { env } = await makeEnv();
  for (let i = 0; i < 20; i++) assert.equal((await reg(env)).status, 200);
  assert.equal((await reg(env)).status, 429);
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
  assert.deepEqual(await r.json(), { active: true, mode: "counts" });
  const last = calls.at(-1);
  assert.equal(last.url, `https://api.sandbox.push.apple.com/3/device/${LA_TOKEN}`);
  assert.equal(last.init.headers["apns-push-type"], "liveactivity");
  assert.equal(last.init.headers["apns-topic"], "app.bergr.push-type.liveactivity");
  assert.deepEqual(sentState(last), { needsYou: 1, working: 3, done: 3, rows: [] });
  assert.ok(!env.REGISTRATIONS.m.get([...env.REGISTRATIONS.m.keys()].find((k) => k.startsWith("las:"))).includes("secret project"));
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
  assert.equal(await env.REGISTRATIONS.get([...env.REGISTRATIONS.m.keys()].find((k) => k.startsWith("la:")) ?? "none"), null);
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

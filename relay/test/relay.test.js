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

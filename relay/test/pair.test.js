import test from "node:test";
import assert from "node:assert/strict";
import { handle } from "../src/index.js";

class KV {
  constructor() { this.m = new Map(); this.ttls = []; }
  async get(k) { return this.m.has(k) ? this.m.get(k) : null; }
  async put(k, v, o = {}) { this.m.set(k, v); if (o.expirationTtl) this.ttls.push(o.expirationTtl); }
  async delete(k) { this.m.delete(k); }
}

const TOKEN = "AAAAAAAAAAAAAAAAAAAAAA"; // 22 chars: 128 bits, base64url
const url = (t = TOKEN) => `https://relay.test/pair/${t}`;
const post = (env, body, t, headers = {}) => handle(new Request(url(t), { method: "POST", body, headers }), env);
const get = (env, t) => handle(new Request(url(t)), env);

test("pair: POST then GET returns the message once", async () => {
  const env = { REGISTRATIONS: new KV() };
  assert.equal((await post(env, "sealed")).status, 204);
  const r = await get(env);
  assert.equal(r.status, 200);
  assert.equal(await r.text(), "sealed");
  assert.equal((await get(env)).status, 404);
});

test("pair: GET with nothing stored is 404", async () => {
  assert.equal((await get({ REGISTRATIONS: new KV() })).status, 404);
});

test("pair: one message per token", async () => {
  const env = { REGISTRATIONS: new KV() };
  assert.equal((await post(env, "first")).status, 204);
  assert.equal((await post(env, "second")).status, 409);
  assert.equal(await (await get(env)).text(), "first");
});

test("pair: stores a hash of the token with a 5 minute TTL", async () => {
  const env = { REGISTRATIONS: new KV() };
  await post(env, "x");
  assert.deepEqual(env.REGISTRATIONS.ttls, [300]);
  assert.ok(![...env.REGISTRATIONS.m.keys()].some((k) => k.includes(TOKEN)));
});

test("pair: expired messages are gone", async (t) => {
  const env = { REGISTRATIONS: new KV() };
  const now = Date.now();
  t.mock.method(Date, "now", () => now);
  await post(env, "x");
  Date.now.mock.mockImplementation(() => now + 5 * 60 * 1000 + 1);
  assert.equal((await get(env)).status, 404);
});

test("pair: rejects bodies over 4 KB and empty ones", async () => {
  const env = { REGISTRATIONS: new KV() };
  assert.equal((await post(env, "x".repeat(4097))).status, 413);
  assert.equal((await post(env, "")).status, 400);
  assert.equal((await post(env, "x".repeat(4096))).status, 204);
});

test("pair: rejects malformed tokens", async () => {
  const env = { REGISTRATIONS: new KV() };
  assert.equal((await post(env, "x", "short")).status, 404);
  assert.equal((await post(env, "x", "a.b" + TOKEN)).status, 404);
});

test("pair: rate limited per hashed IP", async () => {
  const keys = [];
  let n = 0;
  const env = {
    REGISTRATIONS: new KV(),
    PAIR_LIMITER: { limit: async ({ key }) => { keys.push(key); return { success: ++n <= 2 }; } },
  };
  const h = { "CF-Connecting-IP": "1.2.3.4" };
  assert.equal((await handle(new Request(url(), { headers: h }), env)).status, 404);
  assert.equal((await post(env, "x", TOKEN, h)).status, 204);
  assert.equal((await handle(new Request(url(), { headers: h }), env)).status, 429);
  assert.ok(keys.every((k) => k !== "1.2.3.4" && k.length === 64));
});

test("pair: never logs the token", async (t) => {
  const logs = [];
  for (const f of ["log", "error", "warn", "info"]) t.mock.method(console, f, (...a) => logs.push(a.join(" ")));
  const env = { REGISTRATIONS: new KV() };
  await post(env, "x");
  await get(env);
  await get(env);
  assert.ok(!logs.some((l) => l.includes(TOKEN)));
});

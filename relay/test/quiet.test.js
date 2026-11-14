import test from "node:test";
import assert from "node:assert/strict";
import { handle, scheduled, _resetCache, Device } from "../src/index.js";

class KV {
  constructor() { this.m = new Map(); }
  async get(k) { return this.m.has(k) ? this.m.get(k) : null; }
  async put(k, v) { this.m.set(k, v); }
  async delete(k) { this.m.delete(k); }
  async list({ prefix = "" } = {}) {
    return { keys: [...this.m.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })), list_complete: true };
  }
}

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

class DONamespace {
  constructor() { this.devices = new Map(); }
  idFromName(name) { return name; }
  get(id) {
    if (!this.devices.has(id)) this.devices.set(id, new Device({ storage: new Storage() }, {}));
    const device = this.devices.get(id);
    return { fetch: (request) => device.fetch(request) };
  }
}

const realFetch = globalThis.fetch;
const realNow = Date.now;
let calls;
let clock;
test.beforeEach(() => {
  _resetCache();
  calls = [];
  clock = 1_700_000_000_000;
  Date.now = () => clock;
  globalThis.fetch = async (url, init) => { calls.push({ url, init }); return new Response("", { status: 200 }); };
});
test.after(() => { globalThis.fetch = realFetch; Date.now = realNow; });

async function makeEnv() {
  const { privateKey } = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = Buffer.from(await crypto.subtle.exportKey("pkcs8", privateKey)).toString("base64");
  const pem = `-----BEGIN PRIVATE KEY-----\n${der.match(/.{1,64}/g).join("\n")}\n-----END PRIVATE KEY-----\n`;
  return {
    REGISTRATIONS: new KV(), DEVICE: new DONamespace(), APNS_TEAM_ID: "T",
    APNS_SANDBOX_KEY_ID: "K", APNS_SANDBOX_KEY: pem, APNS_PRODUCTION_KEY_ID: "K", APNS_PRODUCTION_KEY: pem,
  };
}

const TOKEN = "ab".repeat(32);
const req = (path, method, body, secret) =>
  new Request("https://relay.test" + path, {
    method,
    headers: { "CF-Connecting-IP": "1.2.3.4", ...(secret ? { authorization: `Bearer ${secret}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
const register = async (env) => (await (await handle(req("/v1/register", "POST", { token: TOKEN, bundle_id: "app.bergr", sandbox: true }), env)).json()).secret;
const beat = (env, secret, over = {}) =>
  handle(req("/v1/heartbeat", "POST", { machine: "m1", name: "pop-os", needsYou: 0, working: 2, done: 0, version: 19, ...over }, secret), env);
const minutes = (n) => { clock += n * 60 * 1000; };
const alerts = () => calls.map((c) => JSON.parse(c.init.body).aps.alert.body);

test("working machine that goes quiet for 15 min is reported once", async () => {
  const env = await makeEnv();
  const secret = await register(env);
  assert.equal((await beat(env, secret)).status, 200);
  minutes(10);
  await scheduled(env);
  assert.deepEqual(alerts(), []);
  minutes(6);
  await scheduled(env);
  assert.deepEqual(alerts(), ["pop-os went quiet while 2 agents were working"]);
  minutes(30);
  await scheduled(env);
  assert.equal(calls.length, 1);
});

test("hearing from the machine again re-arms the alert", async () => {
  const env = await makeEnv();
  const secret = await register(env);
  await beat(env, secret, { working: 1 });
  minutes(16);
  await scheduled(env);
  await beat(env, secret, { working: 1 });
  minutes(16);
  await scheduled(env);
  assert.deepEqual(alerts(), ["pop-os went quiet while 1 agent was working", "pop-os went quiet while 1 agent was working"]);
});

test("an idle last heartbeat (working 0) never alerts", async () => {
  const env = await makeEnv();
  const secret = await register(env);
  await beat(env, secret, { working: 0 });
  minutes(60);
  await scheduled(env);
  assert.equal(calls.length, 0);
});

test("a machine that never sent a heartbeat (old helper) is ignored", async () => {
  const env = await makeEnv();
  const secret = await register(env);
  await handle(req("/v1/activity", "POST", { token: "cd".repeat(32), mode: "counts" }, secret), env);
  await handle(req("/v1/activity/state", "POST", { machine: "old", working: 3 }, secret), env);
  calls.length = 0;
  minutes(60);
  await scheduled(env);
  assert.equal(calls.length, 0);
});

test("errors pref off silences the alert; on again alerts", async () => {
  const env = await makeEnv();
  const secret = await register(env);
  await handle(req("/v1/prefs", "POST", { errors: false }, secret), env);
  await beat(env, secret);
  minutes(16);
  await scheduled(env);
  assert.equal(calls.length, 0);
  await handle(req("/v1/prefs", "POST", { errors: true }, secret), env);
  await beat(env, secret);
  minutes(16);
  await scheduled(env);
  assert.equal(calls.length, 1);
});

test("a badge-only prefs post keeps the errors pref", async () => {
  const env = await makeEnv();
  const secret = await register(env);
  await handle(req("/v1/prefs", "POST", { badge: true, errors: false }, secret), env);
  await handle(req("/v1/prefs", "POST", { badge: false }, secret), env);
  await beat(env, secret);
  minutes(16);
  await scheduled(env);
  assert.equal(calls.length, 0);
});

test("GET /v1/machines reports last heard, and needs auth", async () => {
  const env = await makeEnv();
  const secret = await register(env);
  assert.equal((await handle(req("/v1/machines", "GET"), env)).status, 401);
  assert.equal((await handle(req("/v1/machines", "GET", undefined, "nope"), env)).status, 401);
  await beat(env, secret);
  minutes(7);
  const out = await (await handle(req("/v1/machines", "GET", undefined, secret), env)).json();
  assert.equal(out.machines.length, 1);
  assert.equal(out.machines[0].id, "m1");
  assert.equal(out.machines[0].name, "pop-os");
  assert.equal(out.now - out.machines[0].at, 7 * 60 * 1000);
});

test("heartbeat needs auth and a machine id", async () => {
  const env = await makeEnv();
  const secret = await register(env);
  assert.equal((await beat(env, undefined)).status, 401);
  assert.equal((await beat(env, secret, { machine: "" })).status, 400);
});

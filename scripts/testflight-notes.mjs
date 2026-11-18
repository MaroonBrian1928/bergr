#!/usr/bin/env node
// Sets a TestFlight build's "What to Test" (the notes testers see in the TestFlight app).
//
//   source .envrc.local   # BERGR_ASC_KEY_PATH, BERGR_ASC_KEY_ID, BERGR_ASC_KEY_ISSUER
//   node scripts/testflight-notes.mjs <version> <build> <notes file>
//   e.g. node scripts/testflight-notes.mjs 0.3.17 1 appstore/testflight/0.3.17.md
//
// The build must have finished processing (it can take a few minutes after the upload); the script
// waits up to 20 minutes for it to appear. Notes are at most 4000 characters, in en-US.
import { createSign } from "node:crypto";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";

const [version, build, file] = process.argv.slice(2);
if (!version || !build || !file) {
  console.error("usage: testflight-notes.mjs <version> <build> <notes file>");
  process.exit(2);
}
const notes = readFileSync(file, "utf8").trim();
if (notes.length > 4000) { console.error(`notes are ${notes.length} characters; 4000 at most`); process.exit(2); }
const bundleId = `${process.env.BERGR_BUNDLE_ID_PREFIX || "com.pavelzw"}.bergr`;
const keyPath = (process.env.BERGR_ASC_KEY_PATH || "").replace(/^~/, homedir());
const { BERGR_ASC_KEY_ID: keyId, BERGR_ASC_KEY_ISSUER: issuer } = process.env;
if (!keyPath || !keyId || !issuer) { console.error("source .envrc.local first (App Store Connect API key)"); process.exit(1); }

const b64url = (data) => Buffer.from(data).toString("base64url");
function token() {
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: "ES256", kid: keyId, typ: "JWT" }));
  const body = b64url(JSON.stringify({ iss: issuer, iat: now, exp: now + 15 * 60, aud: "appstoreconnect-v1" }));
  const signer = createSign("SHA256");
  signer.update(`${head}.${body}`);
  return `${head}.${body}.${b64url(signer.sign({ key: readFileSync(keyPath, "utf8"), dsaEncoding: "ieee-p1363" }))}`;
}
async function asc(method, path, body) {
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method, headers: { Authorization: `Bearer ${token()}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path}: ${res.status} ${text}`);
  return text ? JSON.parse(text) : {};
}

const apps = await asc("GET", `/v1/apps?filter[bundleId]=${encodeURIComponent(bundleId)}`);
const app = apps.data.find((a) => a.attributes.bundleId === bundleId);
if (!app) throw new Error(`No app with bundle id ${bundleId}`);

let found;
for (let i = 0; i < 40 && !found; i++) {
  const builds = await asc("GET", `/v1/builds?filter[app]=${app.id}&filter[version]=${encodeURIComponent(build)}`
    + `&filter[preReleaseVersion.version]=${encodeURIComponent(version)}&limit=5`);
  found = builds.data[0];
  if (!found) { if (i === 0) console.log("Waiting for the build to appear in App Store Connect…"); await new Promise((r) => setTimeout(r, 30000)); }
}
if (!found) throw new Error(`Build ${version} (${build}) not found after 20 minutes`);

const locs = await asc("GET", `/v1/builds/${found.id}/betaBuildLocalizations`);
const en = locs.data.find((l) => l.attributes.locale === "en-US");
if (en) {
  await asc("PATCH", `/v1/betaBuildLocalizations/${en.id}`,
    { data: { type: "betaBuildLocalizations", id: en.id, attributes: { whatsNew: notes } } });
} else {
  await asc("POST", "/v1/betaBuildLocalizations", { data: { type: "betaBuildLocalizations",
    attributes: { locale: "en-US", whatsNew: notes }, relationships: { build: { data: { type: "builds", id: found.id } } } } });
}
console.log(`What to Test set for ${version} (${build}).`);

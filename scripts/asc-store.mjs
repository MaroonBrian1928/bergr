#!/usr/bin/env node
// Prepares the App Store version in App Store Connect: names it after the build, attaches the build,
// uploads the App Store screenshots, and adds each tip's review screenshot. It never submits.
//
//   source .envrc.local   # BERGR_ASC_KEY_PATH, BERGR_ASC_KEY_ID, BERGR_ASC_KEY_ISSUER
//   node scripts/asc-store.mjs build <version> <build>            # e.g. build 0.3.17 1
//   node scripts/asc-store.mjs shots <APP_IPHONE_67|APP_IPAD_PRO_3GEN_129> <dir>
//                                                                 # replaces that size's en-US set with <dir>/*.png, in name order
//   node scripts/asc-store.mjs tip-shot <png>                     # the same review screenshot on every tip
import { createHash, createSign } from "node:crypto";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { basename, join } from "node:path";
import { homedir } from "node:os";

const keyPath = (process.env.BERGR_ASC_KEY_PATH || "").replace(/^~/, homedir());
const keyId = process.env.BERGR_ASC_KEY_ID;
const issuer = process.env.BERGR_ASC_KEY_ISSUER;
if (!keyPath || !keyId || !issuer) {
  console.error("Set BERGR_ASC_KEY_PATH, BERGR_ASC_KEY_ID and BERGR_ASC_KEY_ISSUER (source .envrc.local).");
  process.exit(1);
}
const bundleId = `${process.env.BERGR_BUNDLE_ID_PREFIX || "com.pavelzw"}.bergr`;

const b64url = (data) => Buffer.from(data).toString("base64url");
function token() {
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: "ES256", kid: keyId, typ: "JWT" }));
  const body = b64url(JSON.stringify({ iss: issuer, iat: now, exp: now + 15 * 60, aud: "appstoreconnect-v1" }));
  const signer = createSign("SHA256");
  signer.update(`${head}.${body}`);
  const sig = signer.sign({ key: readFileSync(keyPath, "utf8"), dsaEncoding: "ieee-p1363" });
  return `${head}.${body}.${b64url(sig)}`;
}
async function asc(method, path, body) {
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: { Authorization: `Bearer ${token()}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path}: ${res.status} ${text}`);
  return text ? JSON.parse(text) : {};
}

// Reserve, upload the parts, then commit with the checksum. `type` is the asset's resource type.
async function upload(type, relationships, file) {
  const bytes = readFileSync(file);
  const reserved = await asc("POST", `/v1/${type}`, {
    data: { type, attributes: { fileName: basename(file), fileSize: bytes.length }, relationships },
  });
  for (const op of reserved.data.attributes.uploadOperations) {
    const headers = Object.fromEntries(op.requestHeaders.map((h) => [h.name, h.value]));
    const res = await fetch(op.url, { method: op.method, headers, body: bytes.subarray(op.offset, op.offset + op.length) });
    if (!res.ok) throw new Error(`upload ${basename(file)}: ${res.status} ${await res.text()}`);
  }
  const checksum = createHash("md5").update(bytes).digest("hex");
  await asc("PATCH", `/v1/${type}/${reserved.data.id}`, {
    data: { type, id: reserved.data.id, attributes: { uploaded: true, sourceFileChecksum: checksum } },
  });
  console.log(`  uploaded ${basename(file)}`);
}

const app = (await asc("GET", `/v1/apps?filter[bundleId]=${encodeURIComponent(bundleId)}`)).data.find(
  (a) => a.attributes.bundleId === bundleId,
);
if (!app) throw new Error(`No app with bundle id ${bundleId}`);
const editable = ["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"];
const versions = await asc("GET", `/v1/apps/${app.id}/appStoreVersions?filter[platform]=IOS`);
const version = versions.data.find((v) => editable.includes(v.attributes.appStoreState));
if (!version) throw new Error("No iOS App Store version that can still be edited");

const [cmd, ...rest] = process.argv.slice(2);
if (cmd === "build") {
  const [versionString, buildNumber] = rest;
  if (version.attributes.versionString !== versionString) {
    await asc("PATCH", `/v1/appStoreVersions/${version.id}`, {
      data: { type: "appStoreVersions", id: version.id, attributes: { versionString } },
    });
    console.log(`Version ${version.attributes.versionString} renamed ${versionString}`);
  }
  const builds = await asc(
    "GET",
    `/v1/builds?filter[app]=${app.id}&filter[preReleaseVersion.version]=${versionString}&filter[version]=${buildNumber}&filter[preReleaseVersion.platform]=IOS`,
  );
  const build = builds.data[0];
  if (!build) throw new Error(`No build ${versionString} (${buildNumber})`);
  await asc("PATCH", `/v1/appStoreVersions/${version.id}/relationships/build`, { data: { type: "builds", id: build.id } });
  console.log(`Build ${versionString} (${buildNumber}) attached`);
} else if (cmd === "shots") {
  const [displayType, dir] = rest;
  const files = readdirSync(dir).filter((f) => f.endsWith(".png")).sort().map((f) => join(dir, f));
  if (!files.length || files.length > 10) throw new Error(`${dir} needs 1 to 10 PNGs, has ${files.length}`);
  const locs = await asc("GET", `/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations`);
  const loc = locs.data.find((l) => l.attributes.locale === "en-US") ?? locs.data[0];
  const sets = await asc("GET", `/v1/appStoreVersionLocalizations/${loc.id}/appScreenshotSets`);
  let set = sets.data.find((s) => s.attributes.screenshotDisplayType === displayType);
  if (set) {
    const old = await asc("GET", `/v1/appScreenshotSets/${set.id}/appScreenshots`);
    for (const s of old.data) await asc("DELETE", `/v1/appScreenshots/${s.id}`);
    if (old.data.length) console.log(`  removed ${old.data.length} old screenshots`);
  } else {
    set = (
      await asc("POST", "/v1/appScreenshotSets", {
        data: {
          type: "appScreenshotSets",
          attributes: { screenshotDisplayType: displayType },
          relationships: { appStoreVersionLocalization: { data: { type: "appStoreVersionLocalizations", id: loc.id } } },
        },
      })
    ).data;
  }
  console.log(`${displayType} (${loc.attributes.locale}): ${files.length} screenshots`);
  for (const f of files) {
    await upload("appScreenshots", { appScreenshotSet: { data: { type: "appScreenshotSets", id: set.id } } }, f);
  }
} else if (cmd === "tip-shot") {
  const [file] = rest;
  statSync(file);
  const iaps = await asc("GET", `/v1/apps/${app.id}/inAppPurchasesV2?limit=200`);
  for (const iap of iaps.data.filter((p) => p.attributes.productId.startsWith(`${bundleId}.tip.`))) {
    console.log(iap.attributes.productId);
    const current = await asc("GET", `/v2/inAppPurchases/${iap.id}/appStoreReviewScreenshot`).catch(() => ({ data: null }));
    if (current.data) await asc("DELETE", `/v1/inAppPurchaseAppStoreReviewScreenshots/${current.data.id}`);
    await upload(
      "inAppPurchaseAppStoreReviewScreenshots",
      { inAppPurchaseV2: { data: { type: "inAppPurchases", id: iap.id } } },
      file,
    );
  }
} else {
  console.error("usage: asc-store.mjs build <version> <build> | shots <displayType> <dir> | tip-shot <png>");
  process.exit(2);
}

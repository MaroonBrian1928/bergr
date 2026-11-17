#!/usr/bin/env node
// Creates Bergr's three optional tips (consumable in-app purchases) in App Store Connect.
//
//   source .envrc.local   # BERGR_ASC_KEY_PATH, BERGR_ASC_KEY_ID, BERGR_ASC_KEY_ISSUER
//   node scripts/asc-create-tips.mjs                      # dry run: prints what it would do
//   node scripts/asc-create-tips.mjs --prices 2.99,4.99,9.99 --apply
//
// Options:
//   --bundle-id <id>   the app's bundle id (default: $BERGR_BUNDLE_ID_PREFIX.bergr, else com.pavelzw.bergr)
//   --prices a,b,c     US prices for small, medium, large (default 2.99,4.99,9.99); each must match
//                      one of Apple's USD price points, and the other territories follow Apple's
//                      equalization
//   --apply            actually create them (without it, nothing is sent except read-only lookups,
//                      and only when the key is available)
//
// Product ids are "<bundle id>.tip.small|medium|large", the ids the app derives at runtime
// (TipProducts in bergr/Settings/TipJar.swift). A future subscription would use "<bundle id>.pro.*".
// Existing products with the same id are skipped. Review screenshots still have to be added by hand
// before submitting the tips with an app version.
import { createSign } from "node:crypto";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : fallback;
};
const apply = args.includes("--apply");
const bundleId = opt("--bundle-id", `${process.env.BERGR_BUNDLE_ID_PREFIX || "com.pavelzw"}.bergr`);
const prices = opt("--prices", "2.99,4.99,9.99").split(",").map((p) => p.trim());
if (prices.length !== 3 || prices.some((p) => !/^\d+(\.\d{2})?$/.test(p))) {
  console.error("--prices needs three prices like 2.99,4.99,9.99");
  process.exit(2);
}

const tips = [
  ["small", "Small tip", "Tip small"],
  ["medium", "Medium tip", "Tip medium"],
  ["large", "Large tip", "Tip large"],
].map(([size, displayName, referenceName], i) => ({
  productId: `${bundleId}.tip.${size}`,
  referenceName,
  displayName,
  description: "A tip to support Bergr. It unlocks nothing.",
  price: prices[i],
}));

console.log(`${apply ? "Creating" : "Dry run, would create"} for ${bundleId}:`);
for (const t of tips) {
  console.log(`  ${t.productId}  "${t.referenceName}"  en-US "${t.displayName}": ${t.description}  $${t.price}`);
}

const keyPath = (process.env.BERGR_ASC_KEY_PATH || "").replace(/^~/, homedir());
const keyId = process.env.BERGR_ASC_KEY_ID;
const issuer = process.env.BERGR_ASC_KEY_ISSUER;
if (!keyPath || !keyId || !issuer) {
  if (apply) {
    console.error("Set BERGR_ASC_KEY_PATH, BERGR_ASC_KEY_ID and BERGR_ASC_KEY_ISSUER (source .envrc.local).");
    process.exit(1);
  }
  console.log("(No API key in the environment: skipping the read-only lookups.)");
  process.exit(0);
}

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

const apps = await asc("GET", `/v1/apps?filter[bundleId]=${encodeURIComponent(bundleId)}`);
const app = apps.data.find((a) => a.attributes.bundleId === bundleId);
if (!app) throw new Error(`No app with bundle id ${bundleId} in App Store Connect`);
console.log(`App: ${app.attributes.name} (${app.id})`);

const existing = await asc("GET", `/v1/apps/${app.id}/inAppPurchasesV2?limit=200`);
const have = new Set(existing.data.map((p) => p.attributes.productId));

for (const t of tips) {
  if (have.has(t.productId)) {
    console.log(`= ${t.productId} exists, skipped`);
    continue;
  }
  if (!apply) {
    console.log(`+ ${t.productId} would be created`);
    continue;
  }
  const iap = await asc("POST", "/v2/inAppPurchases", {
    data: {
      type: "inAppPurchases",
      attributes: { name: t.referenceName, productId: t.productId, inAppPurchaseType: "CONSUMABLE" },
      relationships: { app: { data: { type: "apps", id: app.id } } },
    },
  });
  const id = iap.data.id;
  await asc("POST", "/v1/inAppPurchaseLocalizations", {
    data: {
      type: "inAppPurchaseLocalizations",
      attributes: { locale: "en-US", name: t.displayName, description: t.description },
      relationships: { inAppPurchaseV2: { data: { type: "inAppPurchases", id } } },
    },
  });
  // Find the USD price point and set it as the base price (other territories equalize).
  let point;
  let next = `/v2/inAppPurchases/${id}/pricePoints?filter[territory]=USA&limit=200`;
  while (next && !point) {
    const page = await asc("GET", next);
    point = page.data.find((p) => Number(p.attributes.customerPrice) === Number(t.price));
    next = page.links?.next?.replace("https://api.appstoreconnect.apple.com", "");
  }
  if (!point) throw new Error(`$${t.price} is not a USD price point (created ${t.productId} without a price)`);
  await asc("POST", "/v1/inAppPurchasePriceSchedules", {
    data: {
      type: "inAppPurchasePriceSchedules",
      relationships: {
        inAppPurchase: { data: { type: "inAppPurchases", id } },
        baseTerritory: { data: { type: "territories", id: "USA" } },
        manualPrices: { data: [{ type: "inAppPurchasePrices", id: "${price}" }] },
      },
    },
    included: [
      {
        type: "inAppPurchasePrices",
        id: "${price}",
        attributes: { startDate: null },
        relationships: { inAppPurchasePricePoint: { data: { type: "inAppPurchasePricePoints", id: point.id } } },
      },
    ],
  });
  console.log(`+ ${t.productId} created (${id}), $${t.price}`);
}
if (!apply) console.log("Dry run: nothing was created. Add --apply to create.");

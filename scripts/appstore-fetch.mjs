#!/usr/bin/env node
// Fetch real App Store install numbers and write marketing/data/appstore.json.
//
// The key stays on THIS machine — nothing secret is ever written to the repo,
// only the resulting counts. Run it manually, or on a schedule via launchd.
//
// Credentials (App Store Connect → Users and Access → Integrations → App Store
// Connect API). Provide them via a gitignored file at ~/.jot-appstore.json:
//   {
//     "issuerId":     "57246542-...-...-...-...",   // the one Issuer ID at the top
//     "keyId":        "2X9R4HXF34",                  // the key's Key ID
//     "p8Path":       "/Users/you/keys/AuthKey_2X9R4HXF34.p8",
//     "vendorNumber": "87654321",                    // Payments and Financial Reports → top-left
//     "appleId":      "6766447330"                   // App Store numeric app id
//   }
// ...or the same as env vars: APPSTORE_ISSUER_ID, APPSTORE_KEY_ID,
// APPSTORE_P8_PATH, APPSTORE_VENDOR_NUMBER, APPSTORE_APPLE_ID.
//
// Usage:  node scripts/appstore-fetch.mjs            # write the file
//         node scripts/appstore-fetch.mjs --commit   # write + git commit + push

import crypto from 'node:crypto';
import zlib from 'node:zlib';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execSync } from 'node:child_process';

const REPO_ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const OUT = path.join(REPO_ROOT, 'marketing/data/appstore.json');

function loadConfig() {
  const file = path.join(os.homedir(), '.jot-appstore.json');
  let c = {};
  if (fs.existsSync(file)) c = JSON.parse(fs.readFileSync(file, 'utf8'));
  const cfg = {
    issuerId:     process.env.APPSTORE_ISSUER_ID     || c.issuerId,
    keyId:        process.env.APPSTORE_KEY_ID        || c.keyId,
    p8Path:       process.env.APPSTORE_P8_PATH       || c.p8Path,
    vendorNumber: process.env.APPSTORE_VENDOR_NUMBER || c.vendorNumber,
    appleId:      process.env.APPSTORE_APPLE_ID      || c.appleId || '6766447330',
  };
  const missing = ['issuerId', 'keyId', 'p8Path', 'vendorNumber'].filter(k => !cfg[k]);
  if (missing.length) {
    console.error(`Missing credentials: ${missing.join(', ')}.`);
    console.error(`Create ~/.jot-appstore.json (see the header of this file) and re-run.`);
    process.exit(1);
  }
  return cfg;
}

const b64url = b => Buffer.from(b).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');

function makeJWT(cfg) {
  const key = crypto.createPrivateKey(fs.readFileSync(cfg.p8Path, 'utf8'));
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: 'ES256', kid: cfg.keyId, typ: 'JWT' }));
  const payload = b64url(JSON.stringify({ iss: cfg.issuerId, iat: now, exp: now + 1000, aud: 'appstoreconnect-v1' }));
  const sig = crypto.sign('SHA256', Buffer.from(`${header}.${payload}`), { key, dsaEncoding: 'ieee-p1363' });
  return `${header}.${payload}.${b64url(sig)}`;
}

// Pull one DAILY SALES SUMMARY report and return first-time-download units for the app.
async function unitsForDate(jwt, cfg, dateStr) {
  const url = `https://api.appstoreconnect.apple.com/v1/salesReports?` +
    `filter[frequency]=DAILY&filter[reportType]=SALES&filter[reportSubType]=SUMMARY` +
    `&filter[vendorNumber]=${cfg.vendorNumber}&filter[reportDate]=${dateStr}`;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${jwt}`, Accept: 'application/a-gzip' } });
  if (res.status === 404) return null;            // no data for that day yet
  if (!res.ok) throw new Error(`Sales report ${dateStr}: HTTP ${res.status} ${await res.text()}`);
  const tsv = zlib.gunzipSync(Buffer.from(await res.arrayBuffer())).toString('utf8');
  const lines = tsv.trim().split('\n');
  const head = lines[0].split('\t');
  const iAppId = head.indexOf('Apple Identifier');
  const iUnits = head.indexOf('Units');
  const iType = head.indexOf('Product Type Identifier');
  let units = 0;
  for (const line of lines.slice(1)) {
    const f = line.split('\t');
    if (f[iAppId] !== String(cfg.appleId)) continue;
    // Product types beginning with "1" = first-time downloads (excludes updates/redownloads).
    if (!String(f[iType] || '').startsWith('1')) continue;
    units += parseInt(f[iUnits], 10) || 0;
  }
  return units;
}

async function ratings(cfg) {
  try {
    const r = await fetch(`https://itunes.apple.com/lookup?id=${cfg.appleId}`).then(r => r.json());
    return r.results?.[0] || {};
  } catch { return {}; }
}

const ymd = d => d.toISOString().slice(0, 10);

async function main() {
  const cfg = loadConfig();
  const jwt = makeJWT(cfg);
  const r = await ratings(cfg);

  // Cumulative first-time downloads since release (Apple data lags ~1-2 days).
  const release = r.releaseDate ? new Date(r.releaseDate) : new Date(Date.now() - 90 * 864e5);
  let total = 0, counted = 0, lastDataDate = null;
  for (let d = new Date(release); d <= new Date(); d = new Date(d.getTime() + 864e5)) {
    let u = null;
    try { u = await unitsForDate(jwt, cfg, ymd(d)); }
    catch (e) { console.error(String(e.message).slice(0, 120)); }
    if (u != null) { total += u; counted++; lastDataDate = ymd(d); }
  }

  const out = {
    date: ymd(new Date()),
    appId: String(cfg.appleId),
    name: r.trackName || 'Jot Transcribe',
    url: `https://apps.apple.com/us/app/jot-transcribe/id${cfg.appleId}`,
    version: r.version || null,
    price: r.formattedPrice || 'Free',
    ratingCount: r.userRatingCount || 0,
    avgRating: r.averageUserRating ?? null,
    releaseDate: r.releaseDate ? r.releaseDate.slice(0, 10) : null,
    minimumOs: r.minimumOsVersion || null,
    installs: counted > 0 ? total : null,
    installsNote: counted > 0
      ? `First-time downloads since release, summed from ${counted} daily App Store Connect reports (latest data ${lastDataDate}; Apple lags ~1-2 days).`
      : 'No App Store Connect sales data returned yet (new apps can take a few days).',
  };
  fs.writeFileSync(OUT, JSON.stringify(out, null, 2) + '\n');
  console.log(`Wrote ${OUT}: installs=${out.installs}, ratings=${out.ratingCount}`);

  if (process.argv.includes('--commit')) {
    execSync(`git -C "${REPO_ROOT}" add marketing/data/appstore.json`);
    execSync(`git -C "${REPO_ROOT}" commit -m "marketing: App Store install snapshot ${out.date}" --no-verify`, { stdio: 'inherit' });
    execSync(`git -C "${REPO_ROOT}" push origin main`, { stdio: 'inherit' });
  }
}

main().catch(e => { console.error(e); process.exit(1); });

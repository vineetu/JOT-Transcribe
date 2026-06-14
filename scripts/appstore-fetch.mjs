#!/usr/bin/env node
// Fetch App Store downloads via the App Store Connect ANALYTICS REPORTS API.
// This path needs NO vendor number and NO Paid Apps agreement — just the API
// key and the app id. The key stays wherever this runs (your Mac, or the cloud
// agent); only the resulting number is written to marketing/data/appstore.json.
//
// HOW APPLE'S ANALYTICS API WORKS (it's asynchronous):
//   1. POST a one-time report request for the app  → Apple starts generating it
//   2. That generation takes a few HOURS up to ~a day the first time
//   3. Once ready: list reports → pick the downloads report → list daily
//      instances → download the gzipped CSV segment → sum the downloads
// So the FIRST run usually prints "report still generating — re-run later".
// Subsequent runs (or the daily agent) find the data and write the number.
//
// Credentials — via env vars or a gitignored ~/.jot-appstore.json:
//   { "issuerId": "...", "keyId": "...", "p8Path": "/path/AuthKey_XXX.p8",
//     "appleId": "6766447330" }
// (no vendorNumber needed)
//
// Usage:  node scripts/appstore-fetch.mjs            # fetch / kick off
//         node scripts/appstore-fetch.mjs --commit   # also git commit + push

import crypto from 'node:crypto';
import zlib from 'node:zlib';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execSync } from 'node:child_process';

const API = 'https://api.appstoreconnect.apple.com';
const REPO_ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const OUT = path.join(REPO_ROOT, 'marketing/data/appstore.json');
const STATE = path.join(os.homedir(), '.jot-appstore-state.json'); // remembers the report-request id

function cfg() {
  const file = path.join(os.homedir(), '.jot-appstore.json');
  const c = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : {};
  const out = {
    issuerId: process.env.APPSTORE_ISSUER_ID || c.issuerId,
    keyId: process.env.APPSTORE_KEY_ID || c.keyId,
    p8Path: process.env.APPSTORE_P8_PATH || c.p8Path,
    p8: process.env.APPSTORE_P8 || (c.p8Path && fs.existsSync(c.p8Path) ? fs.readFileSync(c.p8Path, 'utf8') : c.p8),
    appleId: process.env.APPSTORE_APPLE_ID || c.appleId || '6766447330',
  };
  const missing = ['issuerId', 'keyId', 'appleId'].filter(k => !out[k]).concat(out.p8 ? [] : ['p8/p8Path']);
  if (missing.length) { console.error(`Missing credentials: ${missing.join(', ')}. See header.`); process.exit(1); }
  return out;
}

const b64url = b => Buffer.from(b).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');

function jwt(c) {
  const key = crypto.createPrivateKey(c.p8);
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: 'ES256', kid: c.keyId, typ: 'JWT' }));
  const body = b64url(JSON.stringify({ iss: c.issuerId, iat: now, exp: now + 900, aud: 'appstoreconnect-v1' }));
  const sig = crypto.sign('SHA256', Buffer.from(`${head}.${body}`), { key, dsaEncoding: 'ieee-p1363' });
  return `${head}.${body}.${b64url(sig)}`;
}

const api = (token, url, opts = {}) =>
  fetch(url.startsWith('http') ? url : API + url, {
    ...opts,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...(opts.headers || {}) },
  });

function loadState() { try { return JSON.parse(fs.readFileSync(STATE, 'utf8')); } catch { return {}; } }
function saveState(s) { try { fs.writeFileSync(STATE, JSON.stringify(s)); } catch {} }

// Ensure a one-time analytics report request exists for the app; return its id.
async function ensureRequest(token, c) {
  const st = loadState();
  if (st.requestId && st.appleId === c.appleId) return st.requestId;
  const res = await api(token, '/v1/analyticsReportRequests', {
    method: 'POST',
    body: JSON.stringify({
      data: {
        type: 'analyticsReportRequests',
        attributes: { accessType: 'ONE_TIME_SNAPSHOT' },
        relationships: { app: { data: { type: 'apps', id: c.appleId } } },
      },
    }),
  });
  const j = await res.json();
  if (!res.ok) throw new Error(`create report request: ${res.status} ${JSON.stringify(j)}`);
  const id = j.data.id;
  saveState({ requestId: id, appleId: c.appleId });
  console.log(`Created analytics report request ${id}. Apple is generating it — re-run in a few hours.`);
  return id;
}

async function pageAll(token, url) {
  let out = [], next = url;
  while (next) { const r = await api(token, next); const j = await r.json(); if (!r.ok) throw new Error(JSON.stringify(j)); out = out.concat(j.data || []); next = j.links?.next; }
  return out;
}

// Find the report whose name describes downloads/installs.
function pickDownloadsReport(reports) {
  // Prefer the clean aggregated downloads report by exact name, else score by keywords.
  const exact = reports.find(r => r.attributes?.name === 'App Downloads Standard');
  if (exact) return exact;
  const score = n => (/^app downloads/i.test(n) ? 4 : 0) + (/download/i.test(n) ? 2 : 0) + (/install/i.test(n) ? 1 : 0) - (/detailed/i.test(n) ? 1 : 0);
  return reports.map(r => ({ r, s: score(r.attributes?.name || '') })).filter(x => x.s > 0).sort((a, b) => b.s - a.s)[0]?.r;
}

function sumDownloads(csv) {
  // Reports are tab-separated. Find a downloads-ish column and sum it.
  const lines = csv.trim().split('\n');
  if (lines.length < 2) return 0;
  const head = lines[0].split('\t').map(h => h.trim());
  let col = head.findIndex(h => /first.?time.?download|total.?download|^downloads$|units/i.test(h));
  if (col < 0) col = head.findIndex(h => /download/i.test(h));
  if (col < 0) { console.error('columns found:', head.join(' | ')); return 0; }
  let sum = 0;
  for (const line of lines.slice(1)) { const v = parseInt(line.split('\t')[col], 10); if (!isNaN(v)) sum += v; }
  return sum;
}

async function ratings(c) {
  try { const r = await fetch(`https://itunes.apple.com/lookup?id=${c.appleId}`).then(r => r.json()); return r.results?.[0] || {}; }
  catch { return {}; }
}

const ymd = d => d.toISOString().slice(0, 10);

async function main() {
  const c = cfg();
  const token = jwt(c);
  const r = await ratings(c);
  let installs = null, note;

  try {
    const reqId = await ensureRequest(token, c);
    const reports = await pageAll(token, `/v1/analyticsReportRequests/${reqId}/reports?limit=200`);
    if (!reports.length) {
      note = 'Report still generating at Apple (can take a few hours to ~a day). Re-run later.';
    } else {
      const rep = pickDownloadsReport(reports);
      if (!rep) { note = `No downloads report among: ${reports.map(x => x.attributes?.name).join(', ')}`; }
      else {
        // Apple may publish the first data at any granularity — take whichever exists.
        let instances = [];
        for (const g of ['DAILY', 'WEEKLY', 'MONTHLY']) {
          instances = await pageAll(token, `/v1/analyticsReports/${rep.id}/instances?filter[granularity]=${g}&limit=200`);
          if (instances.length) break;
        }
        if (!instances.length) note = `Report "${rep.attributes?.name}" exists but Apple has not generated data instances yet — re-run later.`;
        else {
          const latest = instances.sort((a, b) => (a.attributes.processingDate < b.attributes.processingDate ? 1 : -1))[0];
          const segs = await pageAll(token, `/v1/analyticsReportInstances/${latest.id}/segments`);
          let total = 0;
          for (const s of segs) {
            const buf = Buffer.from(await (await fetch(s.attributes.url)).arrayBuffer());
            const csv = (buf[0] === 0x1f && buf[1] === 0x8b) ? zlib.gunzipSync(buf).toString('utf8') : buf.toString('utf8');
            total += sumDownloads(csv);
          }
          installs = total;
          note = `First-time downloads from App Store Connect Analytics (instance ${latest.attributes.processingDate}).`;
        }
      }
    }
  } catch (e) { note = `Analytics fetch error: ${String(e.message).slice(0, 200)}`; console.error(e); }

  const out = {
    date: ymd(new Date()), appId: String(c.appleId), name: r.trackName || 'Jot Transcribe',
    url: `https://apps.apple.com/us/app/jot-transcribe/id${c.appleId}`,
    version: r.version || null, price: r.formattedPrice || 'Free',
    ratingCount: r.userRatingCount || 0, avgRating: r.averageUserRating ?? null,
    releaseDate: r.releaseDate ? r.releaseDate.slice(0, 10) : null, minimumOs: r.minimumOsVersion || null,
    installs, installsNote: note,
  };
  // Only touch the committed file when we actually have an install number —
  // otherwise the working tree churns on every run while Apple is still generating.
  if (installs == null) {
    console.log(`No installs number yet (${note}). Leaving appstore.json untouched; will fill in once Apple has the data.`);
    return;
  }

  // Preserve the public ratings fields already in the file (kept fresh by the cloud agent).
  let prev = {};
  try { prev = JSON.parse(fs.readFileSync(OUT, 'utf8')); } catch {}
  fs.writeFileSync(OUT, JSON.stringify({ ...prev, ...out }, null, 2) + '\n');
  console.log(`Wrote ${OUT}: installs=${installs}, ratings=${out.ratingCount}\n${note}`);

  if (process.argv.includes('--commit')) {
    try {
      execSync(`git -C "${REPO_ROOT}" add marketing/data/appstore.json`);
      execSync(`git -C "${REPO_ROOT}" commit -m "marketing: App Store install snapshot ${out.date}" --no-verify`, { stdio: 'inherit' });
      execSync(`git -C "${REPO_ROOT}" pull --rebase origin main`, { stdio: 'inherit' });
      execSync(`git -C "${REPO_ROOT}" push origin main`, { stdio: 'inherit' });
    } catch (e) { console.log('(commit/push skipped:', String(e.message).slice(0, 80), ')'); }
  }
}
main().catch(e => { console.error(e); process.exit(1); });

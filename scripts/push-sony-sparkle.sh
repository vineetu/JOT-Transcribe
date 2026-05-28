#!/usr/bin/env bash
#
# push-sony-sparkle.sh — upload the Sony Sparkle appcast + DMG to the
# Simple Host that backs the v1.4+ flavor-sony auto-update feed.
#
# Why this script exists: `release-sony.sh` only tags the build and pushes
# to Sony's internal GitHub. The Sparkle feed lives on
# `nurture-ai-playground.dev.kcloud.playstation.net`, which is a separate
# service with its own credentials. Without this push, existing Sony
# users on v(N-1) don't auto-update to vN even though the new DMG is on
# Sony's GitHub.
#
# Usage:
#   ./scripts/push-sony-sparkle.sh
#
# Prereqs:
#   1. `./scripts/release-sony.sh <version>` has just run; the build
#      artifacts are at `dist/appcast.xml` + `dist/Jot-sony.dmg`.
#   2. Sony Simple Host credentials at `<repo>/.simple-host-sony.json`.
#      File is gitignored under `.simple-host-*.json` (see .gitignore).
#      If it's missing or the key is revoked, run:
#         curl -sS -X POST 'https://nurture-ai-playground.dev.kcloud.playstation.net/api/auth' \
#           -H 'Content-Type: application/json' \
#           -H 'X-Skill-Version: 0.3.0' \
#           -d '{"email":"jot.transcribe@sony.com"}'
#      The X-Skill-Version header is required — without it the server
#      returns 409 instead of 200.
#
# The script is idempotent: re-running it bumps the Simple Host site's
# active_version each time but the user-facing URL stays the same.

set -euo pipefail

REPO_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
CONFIG="$REPO_ROOT/.simple-host-sony.json"
APPCAST="$REPO_ROOT/dist/appcast.xml"
DMG="$REPO_ROOT/dist/Jot-sony.dmg"

# Sanity-check inputs before doing anything irreversible.
[[ -f "$CONFIG" ]]  || { echo "[push-sony-sparkle] missing credentials: $CONFIG" >&2; exit 1; }
[[ -f "$APPCAST" ]] || { echo "[push-sony-sparkle] missing appcast: $APPCAST (did you run release-sony.sh first?)" >&2; exit 1; }
[[ -f "$DMG" ]]     || { echo "[push-sony-sparkle] missing DMG: $DMG (did you run release-sony.sh first?)" >&2; exit 1; }

API_KEY=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['api_key'])" "$CONFIG")
BASE_URL=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['base_url'])" "$CONFIG")
USERNAME=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['username'])" "$CONFIG")
SITENAME="jot-sony"

# Stage the artifacts in a fresh temp dir + tar them. tar's `-C` flag
# lets us strip the leading `dist/` so the archive's top-level entries
# are `appcast.xml`, `Jot-sony.dmg`, and `index.html` (what Simple Host
# serves at the site root).
#
# Each PUT to /api/sites/<name> REPLACES the entire site content with
# whatever's in the tarball — there is no merge semantics. So we have
# to bundle every file the site needs every time, including the
# human-facing landing page. We fetch the current `index.html` from
# the live site first (preserving whatever the operator last edited),
# falling back to a generated minimal page if the site is somehow
# empty. Forgetting to include `index.html` is the bug that bricked
# the v1.12 deploy on first attempt.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp "$APPCAST" "$DMG" "$STAGE/"

INDEX_FETCH_CODE=$(curl -sS -o "$STAGE/index.html" -w "%{http_code}" "$BASE_URL/sites/$USERNAME/$SITENAME/")
if [[ "$INDEX_FETCH_CODE" == "200" ]]; then
    echo "[push-sony-sparkle] preserved existing landing page ($(wc -c < "$STAGE/index.html" | tr -d ' ') bytes)"
else
    # Live site is empty or unreachable — generate a minimal placeholder
    # so the root URL doesn't 404. The DMG/appcast version is read off
    # the appcast we're about to ship.
    cat > "$STAGE/index.html" <<HTML
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Jot for Sony — Update Feed</title>
<style>body{font-family:-apple-system,system-ui,sans-serif;max-width:640px;margin:60px auto;padding:0 20px;color:#1a1a1a;line-height:1.5}h1{margin:0 0 8px 0}.sub{color:#666;margin-bottom:24px}a{color:#0066cc;text-decoration:none}a:hover{text-decoration:underline}</style>
</head><body>
<h1>Jot for Sony</h1>
<p class="sub">Internal Sparkle auto-update feed.</p>
<ul>
<li><a href="appcast.xml">appcast.xml</a> — Sparkle feed</li>
<li><a href="Jot-sony.dmg">Jot-sony.dmg</a> — DMG (latest)</li>
</ul>
</body></html>
HTML
    echo "[push-sony-sparkle] live site empty (HTTP $INDEX_FETCH_CODE) — using generated placeholder"
fi

TAR="$STAGE/upload.tar.gz"
tar -czf "$TAR" -C "$STAGE" appcast.xml Jot-sony.dmg index.html
echo "[push-sony-sparkle] staged $(du -h "$TAR" | cut -f1) archive"

# PUT bumps the existing site's active_version. POST would also work but
# would fail if the site doesn't exist; PUT is the documented update verb.
echo "[push-sony-sparkle] uploading to $BASE_URL/api/sites/$SITENAME"
RESP=$(curl -sS -X PUT "$BASE_URL/api/sites/$SITENAME" \
    -H "X-API-Key: $API_KEY" \
    -H "X-Skill-Version: 0.3.0" \
    -H "Content-Type: application/gzip" \
    --data-binary "@$TAR")

# Surface the new active_version so the operator can sanity-check.
NEW_VERSION=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['active_version'])" "$RESP" 2>/dev/null || echo "?")
echo "[push-sony-sparkle] site bumped to active_version=$NEW_VERSION"

# Final verification: GET the live appcast and confirm it serves the
# version we just shipped. The DMG enclosure URL stays stable across
# releases (Simple Host doesn't version asset names), so a successful
# version-match here means existing Sparkle clients will see the new
# release on their next check.
SHIPPED_VERSION=$(grep -oE '<sparkle:shortVersionString>[^<]+' "$APPCAST" | head -1 | sed 's/<sparkle:shortVersionString>//')
LIVE_VERSION=$(curl -sS "$BASE_URL/sites/$USERNAME/$SITENAME/appcast.xml" \
    | grep -oE '<sparkle:shortVersionString>[^<]+' \
    | head -1 \
    | sed 's/<sparkle:shortVersionString>//')

if [[ "$LIVE_VERSION" == "$SHIPPED_VERSION" ]]; then
    echo "[push-sony-sparkle] ✓ live appcast now serves v$LIVE_VERSION"
    echo "[push-sony-sparkle] feed URL: $BASE_URL/sites/$USERNAME/$SITENAME/appcast.xml"
else
    echo "[push-sony-sparkle] ⚠ live appcast still reads v$LIVE_VERSION (expected v$SHIPPED_VERSION) — may be CDN cache; recheck in 30 s" >&2
    exit 2
fi

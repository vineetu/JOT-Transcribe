#!/usr/bin/env bash
# Create the public GitHub release for an already-built, notarized DMG when
# release.sh's own `gh release create` didn't run (e.g. it exited on the
# fast-forward push race). Idempotent-ish: if the release exists, upload the
# DMG with --clobber instead.
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="${1:?usage: publish-github-release.sh vX.Y /path/notes.md}"
NOTES="${2:?usage: publish-github-release.sh vX.Y /path/notes.md}"
REPO="vineetu/JOT-Transcribe"
DMG="dist/Jot.dmg"
[[ -f "$DMG" ]] || { echo "missing $DMG" >&2; exit 1; }
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "[gh] release $TAG exists — uploading DMG (clobber)"
  gh release upload "$TAG" "$DMG" --clobber --repo "$REPO"
  gh release edit "$TAG" --notes-file "$NOTES" --repo "$REPO"
else
  gh release create "$TAG" "$DMG" --repo "$REPO" --title "Jot $TAG" --notes-file "$NOTES"
fi
echo "[gh] done"
gh release view "$TAG" --repo "$REPO" --json tagName,assets --jq '{tag:.tagName, assets:[.assets[].name]}'

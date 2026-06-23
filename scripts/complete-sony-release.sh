#!/usr/bin/env bash
# Finish an already-built+notarized+stapled Sony DMG release: tag, force-push to
# the sony remote (the documented per-cycle force-with-lease pattern), and create
# the SIE GitHub Enterprise release. Used when release-sony.sh got the build done
# but couldn't notarize via the (flaky) keychain profile — we notarized the DMG
# directly instead, so only the git/gh tail remains.
set -euo pipefail
WT="${1:?usage: complete-sony-release.sh <worktree> <tag> <notes>}"
TAG="${2:?tag}"
NOTES="${3:?notes file}"
cd "$WT"
[[ -f dist/Jot-sony.dmg ]] || { echo "missing dist/Jot-sony.dmg" >&2; exit 1; }
git fetch sony
git tag -f "$TAG" HEAD
echo "[sony] pushing HEAD:main + $TAG to sony (force-with-lease)"
git push --force-with-lease sony HEAD:main
git push -f sony "$TAG"
echo "[sony] creating SIE GitHub release"
if GH_HOST=github.sie.sony.com gh release view "$TAG" --repo vsriram/Jot >/dev/null 2>&1; then
  GH_HOST=github.sie.sony.com gh release upload "$TAG" dist/Jot-sony.dmg --clobber --repo vsriram/Jot
  GH_HOST=github.sie.sony.com gh release edit "$TAG" --notes-file "$NOTES" --repo vsriram/Jot
else
  GH_HOST=github.sie.sony.com gh release create "$TAG" dist/Jot-sony.dmg --repo vsriram/Jot --title "Jot $TAG" --notes-file "$NOTES"
fi
echo "[sony] DONE"
GH_HOST=github.sie.sony.com gh release view "$TAG" --repo vsriram/Jot --json tagName,assets --jq '{tag:.tagName, assets:[.assets[].name]}'

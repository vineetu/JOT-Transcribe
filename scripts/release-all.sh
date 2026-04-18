#!/usr/bin/env bash
# Release Jot to both public GitHub and Sony's internal GitHub in one run.
#
# Usage:
#   ./scripts/release-all.sh 1.4
#
# Runs scripts/release.sh twice:
#   1. Public flavor (no env overrides).
#   2. Sony flavor (sources .flavor-sony.env).
#
# Each pass: bump, build, sign, notarize, appcast-if-not-skipped,
# commit + tag + push to that flavor's remote, and `gh release create`
# to that flavor's host. Sony's flavor env disables the public appcast
# and website upload (those are public-only concerns).
set -euo pipefail

VERSION="${1:?Usage: ./scripts/release-all.sh <version>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

log()  { printf "\033[1;34m[release-all]\033[0m %s\n" "$*"; }
fail() { printf "\033[1;31m[release-all]\033[0m ERROR: %s\n" "$*" >&2; exit 1; }

# ---- Safety checks -----------------------------------------------------------
# Clean working tree: no unstaged or staged changes. release.sh stages a
# specific allowlist into a single "Release vX" commit; any pre-existing
# uncommitted edits inside that allowlist would get swept into the release
# commit silently. Force the user to commit or stash first.
if ! git diff --quiet || ! git diff --cached --quiet; then
    fail "Working tree is not clean. Commit or stash your changes before running a release."
fi

# Both remotes must exist. The public pass pushes to `public`, the Sony pass
# pushes to `sony` (set by .flavor-sony.env). Neither is `origin`.
git remote get-url public >/dev/null 2>&1 \
    || fail "Git remote 'public' is missing. Add it with: git remote add public git@github.com:vineetu/JOT-Transcribe.git"
git remote get-url sony >/dev/null 2>&1 \
    || fail "Git remote 'sony' is missing. Add it with: git remote add sony git@github.sie.sony.com:vsriram/Jot.git"

[[ -f ".flavor-sony.env" ]] || fail ".flavor-sony.env missing — cannot run Sony pass."

log "===================================="
log "Pass 1/2: public release v${VERSION}"
log "===================================="
"${SCRIPT_DIR}/release.sh" "${VERSION}"

log ""
log "===================================="
log "Pass 2/2: Sony release v${VERSION}-sony"
log "===================================="
# Run sony pass in a sub-shell so the exported flavor vars don't leak into
# anything the user's login shell runs afterwards.
(
    # shellcheck disable=SC1091
    source .flavor-sony.env
    "${SCRIPT_DIR}/release.sh" "${VERSION}"
)

log ""
log "===================================="
log "Both releases shipped: v${VERSION} (public) + v${VERSION}-sony (sony)"
log "===================================="

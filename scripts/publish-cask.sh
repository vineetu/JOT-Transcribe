#!/usr/bin/env bash
# Publish scripts/homebrew/mac.rb to the Homebrew tap, so that
#
#     brew install --cask vineetu/jot/mac
#
# installs Jot.app and puts the bundled CLI on PATH as `jot-cli`.
#
# Run this AFTER scripts/release.sh has published the GitHub release — the cask
# names a version and a checksum, and both have to describe an asset that is
# actually downloadable. This script refuses to publish otherwise, because a
# cask pointing at a missing or changed DMG fails in the user's terminal rather
# than here.
#
# Env overrides: JOT_TAP_REMOTE, JOT_TAP_DIR.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASK_SRC="${REPO_ROOT}/scripts/homebrew/mac.rb"
TAP_REMOTE="${JOT_TAP_REMOTE:-git@github.com:vineetu/homebrew-jot.git}"
TAP_DIR="${JOT_TAP_DIR:-${HOME}/code/homebrew-jot}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() {
    printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
    exit 1
}

[[ -f "${CASK_SRC}" ]] || fail "no cask at ${CASK_SRC}"

version="$(sed -n 's/^  version "\(.*\)"/\1/p' "${CASK_SRC}")"
sha="$(sed -n 's/^  sha256 "\(.*\)"/\1/p' "${CASK_SRC}")"
[[ -n "${version}" && -n "${sha}" ]] || fail "could not read version/sha256 from ${CASK_SRC}"
log "Cask declares version ${version}"

# ---- Precondition: the release it points at must exist and match ------------
url="https://github.com/vineetu/JOT-Transcribe/releases/download/v${version}/Jot.dmg"
tmp="$(mktemp -t jot-cask-dmg)"
trap 'rm -f "${tmp}"' EXIT
log "Verifying ${url}"
curl -fsSL -o "${tmp}" "${url}" ||
    fail "cannot download the DMG for v${version} — publish the GitHub release first"
actual="$(shasum -a 256 "${tmp}" | awk '{print $1}')"
[[ "${actual}" == "${sha}" ]] ||
    fail "checksum mismatch for v${version}
  cask says: ${sha}
  actual:    ${actual}
Re-run scripts/release.sh, or fix the sha256 by hand."
log "Checksum matches the published DMG"

# ---- Publish ----------------------------------------------------------------
if [[ ! -d "${TAP_DIR}/.git" ]]; then
    log "Cloning the tap into ${TAP_DIR}"
    git clone "${TAP_REMOTE}" "${TAP_DIR}" ||
        fail "could not clone ${TAP_REMOTE} — check access to the tap repo"
fi

cd "${TAP_DIR}"
git fetch origin
git checkout main 2>/dev/null || git checkout -b main
git pull --ff-only origin main 2>/dev/null || true

mkdir -p Casks
cp "${CASK_SRC}" Casks/mac.rb

if git diff --quiet -- Casks/mac.rb; then
    log "Tap already has this cask — nothing to publish"
    exit 0
fi

git add -- Casks/mac.rb
git commit -m "jot ${version}"
git push origin main
log "Published. Users install with: brew install --cask vineetu/jot/mac"

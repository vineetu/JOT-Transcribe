#!/usr/bin/env bash
# Sony release wrapper. Sources the Sony flavor env, asserts safety,
# enables force-push, then hands off to scripts/release.sh.
#
# Why force-push: sony/main diverges from local/public main every Sony
# release cycle. The Sony commit (which release.sh creates ON local
# main with restored-public Info.plist content) replaces the previous
# Sony-only commit on the sony remote. The previous Sony commit is
# preserved by its v<X>-sony tag, so nothing is lost. release.sh
# implements this as --force-with-lease + --force-if-includes, which
# makes the operation safe against concurrent pushes by a teammate.
#
# Usage:
#   ./scripts/release-sony.sh <version>          (e.g. 1.9)
set -euo pipefail

VERSION="${1:?Usage: ./scripts/release-sony.sh <version>  (e.g. 1.9)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

log()  { printf "\033[1;34m[release-sony]\033[0m %s\n" "$*"; }
fail() { printf "\033[1;31m[release-sony]\033[0m ERROR: %s\n" "$*" >&2; exit 1; }

# 1. Need the env file. It's gitignored — must be present locally.
[[ -f .flavor-sony.env ]] \
    || fail ".flavor-sony.env not found. Copy it from a trusted location (it's gitignored)."

# 2. Source the env. This sets JOT_FLAVOR_NAME=sony, JOT_PUSH_REMOTES=sony,
#    JOT_FLAVOR_INFO_PLIST_OVERRIDES, JOT_EXTRA_SWIFT_FLAGS=-DJOT_FLAVOR_1, etc.
# shellcheck disable=SC1091
source .flavor-sony.env

# 3. Sanity-check that the env did what we expect — guards against a
#    malformed flavor file.
[[ "${JOT_FLAVOR_NAME:-}" == "sony" ]] \
    || fail "JOT_FLAVOR_NAME != 'sony' after sourcing .flavor-sony.env — env file is malformed."
[[ -n "${JOT_FLAVOR_TAG_SUFFIX:-}" ]] \
    || fail "JOT_FLAVOR_TAG_SUFFIX is empty after sourcing — env file is malformed."
[[ -n "${JOT_FLAVOR_INFO_PLIST_OVERRIDES:-}" ]] \
    || fail "JOT_FLAVOR_INFO_PLIST_OVERRIDES is empty after sourcing — env file is malformed."
[[ -f "${JOT_FLAVOR_INFO_PLIST_OVERRIDES}" ]] \
    || fail "Overrides file '${JOT_FLAVOR_INFO_PLIST_OVERRIDES}' (from env) doesn't exist."

# 4. Hard-code sony targets + enable force-push. Sony's main diverges
#    from public's per cycle so a fast-forward push will reject; force
#    is the documented expectation. release.sh implements it as
#    --force-with-lease + --force-if-includes for safety.
export JOT_PUSH_REMOTES=sony
export JOT_FORCE_PUSH=1

log "Pre-flight passed. Handing off to scripts/release.sh (flavor=sony, force-push=on)."
exec "${SCRIPT_DIR}/release.sh" "$VERSION"

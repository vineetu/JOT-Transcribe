#!/usr/bin/env bash
# Public release wrapper. Asserts safety preconditions, then hands off
# to scripts/release.sh with public-only defaults.
#
# Why this exists: scripts/release.sh is the shared implementation for
# both flavors, but invoking it directly is dangerous because a sourced
# .flavor-sony.env in the shell, a stale Sony-tainted Info.plist from
# manual testing, or a typo in JOT_PUSH_REMOTES could all push Sony
# content to the public remote. This wrapper makes those mistakes
# impossible by asserting them as preconditions.
#
# Usage:
#   ./scripts/release-public.sh <version>          (e.g. 1.9)
set -euo pipefail

VERSION="${1:?Usage: ./scripts/release-public.sh <version>  (e.g. 1.9)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

log()  { printf "\033[1;34m[release-public]\033[0m %s\n" "$*"; }
fail() { printf "\033[1;31m[release-public]\033[0m ERROR: %s\n" "$*" >&2; exit 1; }

# 1. Refuse if a flavor env was sourced into this shell. Public releases
#    must run in a clean shell — sourcing .flavor-sony.env first would
#    silently turn this into a Sony build pushed to public.
if [[ -n "${JOT_FLAVOR_NAME:-}" ]]; then
    fail "JOT_FLAVOR_NAME='${JOT_FLAVOR_NAME}' is already set. You sourced a flavor env in this shell — run this from a fresh terminal."
fi
if [[ -n "${JOT_FLAVOR_INFO_PLIST_OVERRIDES:-}" ]]; then
    fail "JOT_FLAVOR_INFO_PLIST_OVERRIDES is set — flavor env still in scope. Open a fresh shell."
fi

# 2. Worktree must be clean wrt Info.plist. This is the v1.8 root-cause
#    guard — a stale Sony-tainted Info.plist from manual `xcodebuild
#    archive` testing would otherwise be captured in the release commit.
"${SCRIPT_DIR}/lib/assert-clean-worktree.sh" Resources/Info.plist

# 3. Info.plist must be structurally clean (no FLAVOR_1, no Sony URLs).
"${SCRIPT_DIR}/lib/assert-public-plist.sh" Resources/Info.plist

# 4. Soft warning if .flavor-sony.env is on disk. Suggests the user
#    might have meant to source it but didn't — proceed but make it
#    visible in the log.
if [[ -f ".flavor-sony.env" ]]; then
    log "Note: .flavor-sony.env exists on disk but JOT_FLAVOR_NAME is empty — continuing as a PUBLIC release."
fi

# 5. Hard-code public targets. release.sh's internal cross-check
#    (defense-in-depth) ALSO refuses to push to 'sony' without a flavor
#    name, so even if these get overridden mid-flow the script bails.
export JOT_PUSH_REMOTES=public
export JOT_FORCE_PUSH=

log "Pre-flight passed. Handing off to scripts/release.sh."
exec "${SCRIPT_DIR}/release.sh" "$VERSION"

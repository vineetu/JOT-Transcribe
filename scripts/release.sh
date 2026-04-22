#!/usr/bin/env bash
# Release a new version of Jot.
#
# Usage:
#   ./scripts/release.sh 1.1
#
# Default (no env vars set) produces a public release: builds dist/Jot.dmg,
# generates + commits the Sparkle appcast, tags v<version>, and pushes to the
# `public` remote. The DMG is published via `gh release create` — the website
# download button resolves to it via GitHub's releases/latest/download redirect.
#
# To build a different flavor, source a flavor env file first. Example:
#   source .flavor-<name>.env && ./scripts/release.sh 1.1
# The env file is gitignored and holds flavor-specific values (tag suffix,
# DMG name, gh host/repo, remotes, Info.plist overrides).
#
# Environment variables (all optional; sensible defaults):
#   JOT_FLAVOR_NAME                 If set, written to Info.plist as
#                                   `JotFlavor` for the archive and restored
#                                   via trap on exit.
#   JOT_FLAVOR_TAG_SUFFIX           Appended to the git tag. Default: "".
#                                   Tag is always "v<version><suffix>".
#   JOT_FLAVOR_DMG_NAME             Final DMG filename under dist/.
#                                   Default: "Jot.dmg".
#   JOT_FLAVOR_GH_HOST              If set, exported as GH_HOST for the
#                                   printed `gh release create` command.
#   JOT_FLAVOR_GH_REPO              --repo arg for `gh release create`.
#                                   Default: "vineetu/JOT-Transcribe".
#   JOT_FLAVOR_INFO_PLIST_OVERRIDES Path to a KEY=VALUE file. Each entry is
#                                   applied to Info.plist with `plutil
#                                   -replace <key> -string <value>` before
#                                   the archive and restored on exit.
#   JOT_PUSH_REMOTES                Space-separated remote names to push
#                                   (main + tag) to. Default: "public".
#   JOT_SKIP_APPCAST                If "1", skip Sparkle appcast generation
#                                   and upload. Default: 0 (appcast on).
#   JOT_APPCAST_DOWNLOAD_URL_PREFIX Prefix used for <enclosure url=...> in the
#                                   generated appcast. Sparkle would otherwise
#                                   derive this from SUFeedURL (raw.github...)
#                                   which 404s since no DMG is committed.
#                                   Default: GitHub releases/latest/download/.
#   JOT_SKIP_GH_RELEASE             If "1", skip the automatic `gh release
#                                   create` step and only print the command
#                                   the user can run by hand. Default: 0.

set -euo pipefail

VERSION="${1:?Usage: ./scripts/release.sh <version>  (e.g. 1.1)}"

# ---- Resolve env-var contract (defaults public-release-safe) -----------------
JOT_FLAVOR_NAME="${JOT_FLAVOR_NAME:-}"
JOT_FLAVOR_TAG_SUFFIX="${JOT_FLAVOR_TAG_SUFFIX:-}"
JOT_FLAVOR_DMG_NAME="${JOT_FLAVOR_DMG_NAME:-Jot.dmg}"
JOT_FLAVOR_GH_HOST="${JOT_FLAVOR_GH_HOST:-}"
JOT_FLAVOR_GH_REPO="${JOT_FLAVOR_GH_REPO:-vineetu/JOT-Transcribe}"
JOT_FLAVOR_INFO_PLIST_OVERRIDES="${JOT_FLAVOR_INFO_PLIST_OVERRIDES:-}"
JOT_PUSH_REMOTES="${JOT_PUSH_REMOTES:-public}"
JOT_SKIP_APPCAST="${JOT_SKIP_APPCAST:-0}"
JOT_APPCAST_DOWNLOAD_URL_PREFIX="${JOT_APPCAST_DOWNLOAD_URL_PREFIX:-https://github.com/vineetu/JOT-Transcribe/releases/latest/download/}"
JOT_SKIP_GH_RELEASE="${JOT_SKIP_GH_RELEASE:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLIST="${REPO_ROOT}/Resources/Info.plist"
APPCAST_SRC="${REPO_ROOT}/dist/appcast.xml"
APPCAST_DST="${REPO_ROOT}/appcast.xml"
SPARKLE_BIN="$(find ~/Library/Developer/Xcode/DerivedData/Jot-*/SourcePackages/artifacts/sparkle/Sparkle/bin -name generate_appcast -print -quit 2>/dev/null)"

# build-dmg.sh always emits dist/Jot.dmg; for a custom DMG name we rename it
# right after the build so downstream steps reference the flavored name.
DMG_BUILT="${REPO_ROOT}/dist/Jot.dmg"
DMG_FINAL="${REPO_ROOT}/dist/${JOT_FLAVOR_DMG_NAME}"

TAG="v${VERSION}${JOT_FLAVOR_TAG_SUFFIX}"

log()  { printf "\033[1;34m[release]\033[0m %s\n" "$*"; }
fail() { printf "\033[1;31m[release]\033[0m ERROR: %s\n" "$*" >&2; exit 1; }

cd "${REPO_ROOT}"

# ---- Derive build number from commit count -----------------------------------
BUILD_NUMBER="$(git rev-list --count HEAD)"
BUILD_NUMBER=$((BUILD_NUMBER + 1))

# ---- 1. Bump version ---------------------------------------------------------
log "Bumping to ${VERSION} (build ${BUILD_NUMBER})${JOT_FLAVOR_NAME:+ [flavor: ${JOT_FLAVOR_NAME}]}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${PLIST}"

# ---- 2. Apply Info.plist overrides (flavor + per-key) ------------------------
# Snapshot original values so we can restore on exit. JotFlavor is tracked in
# git with a default (usually "public"); leaving any override on disk after the
# script exits would poison subsequent builds and could get committed.
RESTORE_CMDS=()

snapshot_and_replace_plist_string() {
    local key="$1"
    local new_value="$2"
    local old_value
    if old_value="$(/usr/libexec/PlistBuddy -c "Print :${key}" "${PLIST}" 2>/dev/null)"; then
        RESTORE_CMDS+=("/usr/libexec/PlistBuddy -c 'Set :${key} ${old_value}' '${PLIST}' 2>/dev/null || true")
    else
        RESTORE_CMDS+=("/usr/libexec/PlistBuddy -c 'Delete :${key}' '${PLIST}' 2>/dev/null || true")
    fi
    # Use PlistBuddy so dotted keys (e.g. `JotDefaultEndpoint.openai`) are
    # treated as literal top-level keys. `plutil -replace` on macOS 26 parses
    # the key as a KVC keypath and fails with `Key path not found` on any
    # dotted key — see Apple `plutil(1)` manpage on macOS 26.4. PlistBuddy
    # uses `:key` path syntax with literal key names, matching the snapshot
    # read above.
    if /usr/libexec/PlistBuddy -c "Print :${key}" "${PLIST}" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :${key} ${new_value}" "${PLIST}"
    else
        /usr/libexec/PlistBuddy -c "Add :${key} string ${new_value}" "${PLIST}"
    fi
}

restore_plist() {
    # Run all snapshotted restore commands in reverse order.
    local i
    for ((i=${#RESTORE_CMDS[@]}-1; i>=0; i--)); do
        eval "${RESTORE_CMDS[$i]}"
    done
}

if [[ -n "${JOT_FLAVOR_NAME}" || -n "${JOT_FLAVOR_INFO_PLIST_OVERRIDES}" ]]; then
    trap restore_plist EXIT
fi

if [[ -n "${JOT_FLAVOR_NAME}" ]]; then
    log "Setting JotFlavor=${JOT_FLAVOR_NAME} in Info.plist (restored on exit)"
    snapshot_and_replace_plist_string "JotFlavor" "${JOT_FLAVOR_NAME}"
fi

if [[ -n "${JOT_FLAVOR_INFO_PLIST_OVERRIDES}" ]]; then
    [[ -f "${JOT_FLAVOR_INFO_PLIST_OVERRIDES}" ]] \
        || fail "JOT_FLAVOR_INFO_PLIST_OVERRIDES points at a missing file: ${JOT_FLAVOR_INFO_PLIST_OVERRIDES}"
    log "Applying Info.plist overrides from ${JOT_FLAVOR_INFO_PLIST_OVERRIDES} (restored on exit)"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Skip blanks and comments.
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
        # Split on first '='.
        local_key="${line%%=*}"
        local_value="${line#*=}"
        # Trim whitespace from the key; leave value as-is (URLs may have no
        # whitespace anyway).
        local_key="${local_key#"${local_key%%[![:space:]]*}"}"
        local_key="${local_key%"${local_key##*[![:space:]]}"}"
        [[ -z "${local_key}" ]] && continue
        snapshot_and_replace_plist_string "${local_key}" "${local_value}"
    done < "${JOT_FLAVOR_INFO_PLIST_OVERRIDES}"
fi

# ---- 3. Build, sign, notarize ------------------------------------------------
log "Building DMG"
bash "${SCRIPT_DIR}/build-dmg.sh"

# ---- 4. Rename DMG if a custom name was requested ----------------------------
if [[ "${DMG_FINAL}" != "${DMG_BUILT}" ]]; then
    [[ -f "${DMG_BUILT}" ]] || fail "Expected ${DMG_BUILT} from build-dmg.sh"
    log "Renaming $(basename "${DMG_BUILT}") -> $(basename "${DMG_FINAL}")"
    mv -f "${DMG_BUILT}" "${DMG_FINAL}"
fi

# ---- 5. Generate appcast (opt-out) -------------------------------------------
if [[ "${JOT_SKIP_APPCAST}" != "1" ]]; then
    [[ -n "${SPARKLE_BIN}" ]] || fail "generate_appcast not found. Build in Xcode first to resolve Sparkle SPM package."
    log "Generating appcast"
    "${SPARKLE_BIN}" --download-url-prefix "${JOT_APPCAST_DOWNLOAD_URL_PREFIX}" "${REPO_ROOT}/dist/"
    cp "${APPCAST_SRC}" "${APPCAST_DST}"
fi

# ---- 6. Commit and push ------------------------------------------------------
# Stage everything that belongs in a release commit via an explicit allowlist.
# Deliberately not using `git add -A` / `git add .` — those would sweep in any
# stray file left in the worktree (local experiments, .env files on machines
# where they aren't gitignored, etc.). `git add <path>` still honors
# .gitignore, so dist/, .flavor-*.env, .flavor-*.overrides, etc. stay out.
log "Committing and pushing"
RELEASE_STAGE_PATHS=(
    Sources
    Resources
    docs
    website
    scripts
    README.md
    CLAUDE.md
    .gitignore
)
for path in "${RELEASE_STAGE_PATHS[@]}"; do
    [[ -e "${REPO_ROOT}/${path}" ]] || continue
    git add -- "${path}"
done
# appcast.xml lives at repo root, outside the allowlisted directories.
if [[ "${JOT_SKIP_APPCAST}" != "1" && -f "${APPCAST_DST}" ]]; then
    git add -- "${APPCAST_DST}"
fi
git commit -m "Release ${TAG}"
git tag -a "${TAG}" -m "Jot ${TAG}"

for remote in ${JOT_PUSH_REMOTES}; do
    log "Pushing main + ${TAG} to ${remote}"
    git push "${remote}" main
    git push "${remote}" "${TAG}"
done

# ---- 7. Create GitHub release (opt-out) --------------------------------------
GH_CMD_PREFIX=""
if [[ -n "${JOT_FLAVOR_GH_HOST}" ]]; then
    GH_CMD_PREFIX="GH_HOST=${JOT_FLAVOR_GH_HOST} "
fi

# The exact command the user can re-run by hand if `gh release create` fails
# or is skipped. Kept as a string so we can echo it in both the skip and
# error paths.
GH_RELEASE_CMD="${GH_CMD_PREFIX}gh release create ${TAG} ${DMG_FINAL#${REPO_ROOT}/} --repo ${JOT_FLAVOR_GH_REPO} --title \"Jot ${TAG}\""

if [[ "${JOT_SKIP_GH_RELEASE}" == "1" ]]; then
    log "JOT_SKIP_GH_RELEASE=1 — skipping \`gh release create\`."
    log "To publish the release manually, run:"
    log "  ${GH_RELEASE_CMD}"
else
    log "Creating GitHub release ${TAG} on ${JOT_FLAVOR_GH_REPO}${JOT_FLAVOR_GH_HOST:+ (host: ${JOT_FLAVOR_GH_HOST})}"
    if [[ -n "${JOT_FLAVOR_GH_HOST}" ]]; then
        GH_HOST="${JOT_FLAVOR_GH_HOST}" gh release create "${TAG}" "${DMG_FINAL}" \
            --repo "${JOT_FLAVOR_GH_REPO}" \
            --title "Jot ${TAG}" \
            || { printf "\033[1;31m[release]\033[0m ERROR: \`gh release create\` failed. Re-run by hand:\n  %s\n" "${GH_RELEASE_CMD}" >&2; exit 1; }
    else
        gh release create "${TAG}" "${DMG_FINAL}" \
            --repo "${JOT_FLAVOR_GH_REPO}" \
            --title "Jot ${TAG}" \
            || { printf "\033[1;31m[release]\033[0m ERROR: \`gh release create\` failed. Re-run by hand:\n  %s\n" "${GH_RELEASE_CMD}" >&2; exit 1; }
    fi
fi

# ---- 8. Summary --------------------------------------------------------------
cat <<EOF

---------------------------------------------------------------
  Jot ${TAG} released${JOT_FLAVOR_NAME:+ (flavor: ${JOT_FLAVOR_NAME})}
---------------------------------------------------------------
  DMG     : ${DMG_FINAL#${REPO_ROOT}/}
  Tag     : ${TAG}
  Remotes : ${JOT_PUSH_REMOTES}
  GH repo : ${JOT_FLAVOR_GH_REPO}${JOT_FLAVOR_GH_HOST:+ @ ${JOT_FLAVOR_GH_HOST}}
---------------------------------------------------------------

EOF

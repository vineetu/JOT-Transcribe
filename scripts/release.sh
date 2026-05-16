#!/usr/bin/env bash
# Release a new version of Jot — shared implementation for both flavors.
#
# **PREFER THE WRAPPERS.** Run one of these instead of calling this script
# directly:
#   ./scripts/release-public.sh <version>   # public release, no flavor env
#   ./scripts/release-sony.sh   <version>   # Sony release, force-push to sony
#
# The wrappers add precondition asserts that catch the two known
# failure classes (Sony content leaking into public DMG; sony/main push
# rejected non-fast-forward). This script ALSO enforces the same
# asserts internally as defense in depth, so a direct invocation still
# bails on misconfiguration — but the wrappers fail earlier with a
# clearer message and never leave the worktree mid-build.
#
# Usage (direct, discouraged):
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
#   JOT_FORCE_PUSH                  If "1", push main with
#                                   --force-with-lease + --force-if-includes
#                                   (safe overwrite — only succeeds if the
#                                   remote tip is what we last fetched).
#                                   Sony releases set this because
#                                   sony/main diverges from local main
#                                   each cycle (the previous Sony commit
#                                   is preserved by its v<X>-sony tag).
#                                   Tag push always stays non-force, so
#                                   re-pushing the same version fails
#                                   loudly. Default: "" (plain push).
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
JOT_FORCE_PUSH="${JOT_FORCE_PUSH:-}"
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

# ---- 0. Pre-flight safety asserts -------------------------------------------
# These run BEFORE any version bump, build, or commit. They duplicate the
# checks in scripts/release-public.sh and scripts/release-sony.sh, so a
# direct invocation of this script still fails fast on misconfiguration.

# 0a. Must be on the `main` branch. release.sh's commit goes onto whatever
#     HEAD is, then is pushed as `<remote> main` — running this off a topic
#     branch would commit there and then push to the wrong place.
CURRENT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo "")"
[[ "${CURRENT_BRANCH}" == "main" ]] \
    || fail "Must be on the 'main' branch (currently on '${CURRENT_BRANCH:-<detached>}'). git switch main first."

# 0b. Cross-check JOT_FLAVOR_NAME against JOT_PUSH_REMOTES. A flavor build
#     must NOT push to the public remote, and an unflavored build must
#     NOT push to a flavor remote. This catches both:
#       - public release with stale sony env in shell (would push public-
#         tagged work to sony remote — confusing but recoverable)
#       - sony release with JOT_PUSH_REMOTES typo'd to "public" (would
#         leak Sony work to public users — the v1.8 incident's worst case)
if [[ -n "${JOT_FLAVOR_NAME}" ]]; then
    case " ${JOT_PUSH_REMOTES} " in
        *" public "*) fail "JOT_FLAVOR_NAME='${JOT_FLAVOR_NAME}' but JOT_PUSH_REMOTES contains 'public'. Flavor builds must not push to the public remote." ;;
    esac
else
    case " ${JOT_PUSH_REMOTES} " in
        *" sony "*) fail "No JOT_FLAVOR_NAME but JOT_PUSH_REMOTES contains 'sony'. Public builds must not push to the sony remote." ;;
    esac
fi

# 0c. Tag must not already exist locally. A re-pushed tag is silently
#     accepted by some hosts and rejected by others — fail loudly and
#     ask the user to pick a new version.
TAG_PREVIEW="v${VERSION}${JOT_FLAVOR_TAG_SUFFIX}"
if git rev-parse "${TAG_PREVIEW}" >/dev/null 2>&1; then
    fail "Tag ${TAG_PREVIEW} already exists locally. Pick a new version, or delete it: git tag -d ${TAG_PREVIEW}"
fi

# 0d. Plist asserts. Public-state assertion for unflavored builds;
#     Sony-state assertion is run AFTER overrides are applied (see
#     step 2 below).
if [[ -z "${JOT_FLAVOR_NAME}" ]]; then
    "${SCRIPT_DIR}/lib/assert-clean-worktree.sh" Resources/Info.plist
    "${SCRIPT_DIR}/lib/assert-public-plist.sh" Resources/Info.plist
fi

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

# 2.5. Post-override sony-plist assertion. Runs after overrides are
# applied but BEFORE the DMG is built, so a malformed or empty
# .flavor-sony.overrides gets caught before a bad DMG ships.
if [[ "${JOT_FLAVOR_NAME}" == "sony" ]]; then
    "${SCRIPT_DIR}/lib/assert-sony-plist.sh" "${PLIST}"
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

# ---- 5b. Upload to Simple Host (opt-in via JOT_SIMPLE_HOST_API_KEY) ----------
# Sony uses Simple Host (a Sony-internal anonymous-readable static host) for
# Sparkle auto-update because github.sie.sony.com requires SSO for raw content.
# Public releases leave JOT_SIMPLE_HOST_API_KEY unset and skip this step.
if [[ -n "${JOT_SIMPLE_HOST_API_KEY:-}" ]]; then
    : "${JOT_SIMPLE_HOST_BASE_URL:?required when JOT_SIMPLE_HOST_API_KEY is set}"
    : "${JOT_SIMPLE_HOST_SITENAME:?required when JOT_SIMPLE_HOST_API_KEY is set}"
    log "Uploading appcast + DMG to Simple Host (${JOT_SIMPLE_HOST_SITENAME})"

    UPLOAD_DIR="$(mktemp -d)"
    cat > "${UPLOAD_DIR}/index.html" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Jot for Sony — Update Feed</title>
<style>body{font-family:-apple-system,system-ui,sans-serif;max-width:640px;margin:60px auto;padding:0 20px;color:#1a1a1a;line-height:1.5}h1{margin:0 0 8px 0}.sub{color:#666;margin-bottom:24px}a{color:#0066cc;text-decoration:none}a:hover{text-decoration:underline}</style>
</head>
<body>
<h1>Jot for Sony</h1>
<p class="sub">Internal Sparkle auto-update feed.</p>
<p>Latest release: <strong>${TAG}</strong></p>
<ul>
<li><a href="appcast.xml">appcast.xml</a> — Sparkle feed</li>
<li><a href="${JOT_FLAVOR_DMG_NAME}">${JOT_FLAVOR_DMG_NAME}</a> — DMG (latest)</li>
</ul>
<p class="sub" style="margin-top:40px;font-size:.85em">Contact: jot.transcribe@gmail.com</p>
</body>
</html>
HTML
    cp "${APPCAST_DST}" "${UPLOAD_DIR}/appcast.xml"
    cp "${DMG_FINAL}" "${UPLOAD_DIR}/${JOT_FLAVOR_DMG_NAME}"

    ARCHIVE="$(mktemp -t jot-simple-host).tar.gz"
    tar -czf "${ARCHIVE}" -C "${UPLOAD_DIR}" .

    HTTP_CODE="$(curl -s -o /tmp/simple-host-upload.out -w "%{http_code}" \
        -X PUT "${JOT_SIMPLE_HOST_BASE_URL}/api/sites/${JOT_SIMPLE_HOST_SITENAME}" \
        -H "X-API-Key: ${JOT_SIMPLE_HOST_API_KEY}" \
        -H "Content-Type: application/gzip" \
        --data-binary "@${ARCHIVE}")"
    rm -rf "${UPLOAD_DIR}" "${ARCHIVE}"

    if [[ "${HTTP_CODE}" != "200" ]]; then
        cat /tmp/simple-host-upload.out 2>&1 || true
        fail "Simple Host upload failed (HTTP ${HTTP_CODE})"
    fi
    log "Simple Host upload OK — feed live at ${JOT_SIMPLE_HOST_BASE_URL}/sites/${JOT_SIMPLE_HOST_USERNAME:-?}/${JOT_SIMPLE_HOST_SITENAME}/"
fi

# ---- 6. Restore Info.plist flavor overrides BEFORE commit --------------------
# The DMG built in step 3 already contains the flavor-injected Info.plist, so
# the archive is correct. But the EXIT trap installed earlier fires AFTER
# `git commit` below — meaning, without this explicit restore, flavor keys
# (JotFlavor=sony, JotDefaultEndpoint.*, Sony SUFeedURL, etc.) would get baked
# into the release commit and then propagate to whichever remote main is
# pushed to. That's the exact bug that contaminated public/main with sony
# content across five `-sony` release commits before the history rewrite.
# Restore now, clear the command list so the EXIT trap becomes a no-op.
if [[ ${#RESTORE_CMDS[@]} -gt 0 ]]; then
    log "Restoring Info.plist flavor overrides before git commit"
    restore_plist
    RESTORE_CMDS=()
fi

# ---- 7. Commit and push ------------------------------------------------------
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
    if [[ "${JOT_FORCE_PUSH}" == "1" ]]; then
        # Force-with-lease + force-if-includes: only succeeds if
        # ${remote}/main currently points at exactly the SHA we observe
        # NOW, AND our local main descends from the latest fetched
        # remote main. Plain --force would silently clobber a
        # teammate's just-pushed work; lease alone races with an
        # interleaved `git fetch ${remote}`. The pair is the safe
        # primitive for "overwrite a known-divergent remote tip."
        remote_tip="$(git ls-remote "${remote}" refs/heads/main | awk '{print $1}')"
        [[ -n "${remote_tip}" ]] \
            || fail "Couldn't read ${remote}/main tip for force-with-lease check"
        log "Force-with-lease push: expecting ${remote}/main at ${remote_tip:0:7}"
        git push --force-with-lease="main:${remote_tip}" --force-if-includes "${remote}" main
    else
        git push "${remote}" main
    fi
    # Tag push is ALWAYS non-force. Re-pushing the same tag means
    # re-releasing the same version, which should fail loudly so the
    # caller picks a new version number.
    git push "${remote}" "${TAG}"
done

# ---- 8. Create GitHub release (opt-out) --------------------------------------
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

# ---- 9. Summary --------------------------------------------------------------
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

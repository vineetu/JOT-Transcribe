#!/usr/bin/env bash
# Build a Release-configured, ad-hoc signed DMG for Jot.
#
# Usage:
#   ./scripts/build-dmg.sh                     # uses MARKETING_VERSION from Xcode
#   VERSION=0.2.0 ./scripts/build-dmg.sh       # override the marketing version
#
# Output:
#   dist/Jot-<version>-<shortsha>.dmg  (drag-to-Applications layout)
#
# v1 caveat: the DMG is ad-hoc signed and NOT notarized. Users will see a
# Gatekeeper warning on first launch. Right-click -> Open to bypass once, or
# run `xattr -dr com.apple.quarantine /Applications/Jot.app`. Developer ID +
# notarization is a later phase — see docs/plans/apple-signing.md.

set -euo pipefail

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
DIST_DIR="${REPO_ROOT}/dist"
ARCHIVE_PATH="${BUILD_DIR}/Jot.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
EXPORT_OPTIONS_PLIST="${SCRIPT_DIR}/export-options.plist"
ENTITLEMENTS_PATH="${REPO_ROOT}/Resources/Jot.entitlements"
APP_PATH="${EXPORT_DIR}/Jot.app"
SCHEME="Jot"
CONFIGURATION="Release"

cd "${REPO_ROOT}"

log()  { printf "\033[1;34m[build-dmg]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[build-dmg]\033[0m WARNING: %s\n" "$*" >&2; }
fail() { printf "\033[1;31m[build-dmg]\033[0m ERROR: %s\n" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. Resolve version
# -----------------------------------------------------------------------------
if [[ -n "${VERSION:-}" ]]; then
    MARKETING_VERSION="${VERSION}"
    log "Using VERSION override: ${MARKETING_VERSION}"
else
    MARKETING_VERSION="$(
        xcodebuild -showBuildSettings \
            -scheme "${SCHEME}" \
            -configuration "${CONFIGURATION}" 2>/dev/null \
        | awk -F' = ' '/ MARKETING_VERSION = /{print $2; exit}'
    )"
    [[ -n "${MARKETING_VERSION}" ]] || fail "Could not read MARKETING_VERSION from Xcode."
    log "Read MARKETING_VERSION from Xcode: ${MARKETING_VERSION}"
fi

SHORT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo "nogit")"
FULL_VERSION="${MARKETING_VERSION}-${SHORT_SHA}"
DMG_NAME="Jot-${FULL_VERSION}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
log "Target DMG: ${DMG_PATH}"

# -----------------------------------------------------------------------------
# 2. Clean build / dist (scoped strictly to repo root)
# -----------------------------------------------------------------------------
log "Cleaning build/ and dist/"
case "${BUILD_DIR}" in "${REPO_ROOT}/"*) rm -rf "${BUILD_DIR}" ;; *) fail "refuse to clean ${BUILD_DIR}" ;; esac
case "${DIST_DIR}"  in "${REPO_ROOT}/"*) rm -rf "${DIST_DIR}"  ;; *) fail "refuse to clean ${DIST_DIR}"  ;; esac
mkdir -p "${BUILD_DIR}" "${DIST_DIR}"

# -----------------------------------------------------------------------------
# 3. Archive (Release, arm64)
# -----------------------------------------------------------------------------
log "Archiving ${SCHEME} (${CONFIGURATION}, arm64)"
xcodebuild \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination 'platform=macOS,arch=arm64' \
    -archivePath "${ARCHIVE_PATH}" \
    archive

# -----------------------------------------------------------------------------
# 4. Export .app from the archive
# -----------------------------------------------------------------------------
log "Exporting .app with ${EXPORT_OPTIONS_PLIST}"
xcodebuild \
    -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${EXPORT_OPTIONS_PLIST}"

[[ -d "${APP_PATH}" ]] || fail "Expected ${APP_PATH} after export."

# -----------------------------------------------------------------------------
# 5. Re-apply ad-hoc signature with hardened runtime + entitlements
#    (belt-and-braces: the archive is already signed this way, but explicit
#    is better so the DMG contents match what Gatekeeper will inspect.)
# -----------------------------------------------------------------------------
log "Re-signing ad-hoc with hardened runtime"
codesign \
    --force --deep \
    --sign - \
    --options runtime \
    --entitlements "${ENTITLEMENTS_PATH}" \
    "${APP_PATH}"

# -----------------------------------------------------------------------------
# 6. Verify signature + Gatekeeper assessment
# -----------------------------------------------------------------------------
log "codesign --verify:"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}" 2>&1 || \
    fail "codesign verification failed"

log "spctl assessment (ad-hoc expected to be rejected — not a build failure):"
set +e
SPCTL_OUTPUT="$(spctl -a -vv -t install "${APP_PATH}" 2>&1)"
SPCTL_EXIT=$?
set -e
printf '%s\n' "${SPCTL_OUTPUT}"
if [[ ${SPCTL_EXIT} -ne 0 ]]; then
    warn "spctl rejected the app — this is expected for ad-hoc signing in v1."
    warn "Gatekeeper will block first launch for end users until we ship Developer ID."
fi

# -----------------------------------------------------------------------------
# 7. Build the DMG (drag-to-Applications layout)
# -----------------------------------------------------------------------------
STAGING_DIR="${BUILD_DIR}/dmg-staging"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"
log "Staging DMG contents in ${STAGING_DIR}"
cp -R "${APP_PATH}" "${STAGING_DIR}/Jot.app"
ln -s /Applications "${STAGING_DIR}/Applications"

if command -v create-dmg >/dev/null 2>&1; then
    log "Using create-dmg"
    create-dmg \
        --volname "Jot ${MARKETING_VERSION}" \
        --window-size 540 320 \
        --icon-size 128 \
        --icon "Jot.app" 140 150 \
        --app-drop-link 400 150 \
        --no-internet-enable \
        "${DMG_PATH}" \
        "${STAGING_DIR}"
else
    log "create-dmg not installed — falling back to hdiutil"
    hdiutil create \
        -volname "Jot ${MARKETING_VERSION}" \
        -srcfolder "${STAGING_DIR}" \
        -ov \
        -format UDZO \
        "${DMG_PATH}"
fi

[[ -f "${DMG_PATH}" ]] || fail "DMG was not produced at ${DMG_PATH}"

# -----------------------------------------------------------------------------
# 8. Verify DMG
# -----------------------------------------------------------------------------
log "Verifying DMG integrity"
hdiutil verify "${DMG_PATH}" >/dev/null

DMG_SIZE="$(du -h "${DMG_PATH}" | awk '{print $1}')"
DMG_SHA256="$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"

# -----------------------------------------------------------------------------
# 9. Summary footer
# -----------------------------------------------------------------------------
cat <<EOF

---------------------------------------------------------------
  Jot DMG build complete
---------------------------------------------------------------
  Version : ${FULL_VERSION}
  Path    : ${DMG_PATH}
  Size    : ${DMG_SIZE}
  SHA-256 : ${DMG_SHA256}
  Signing : ad-hoc (no Developer ID, no notarization)
---------------------------------------------------------------
EOF

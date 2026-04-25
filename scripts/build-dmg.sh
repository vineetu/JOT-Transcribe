#!/usr/bin/env bash
# Build a Release-configured, Developer ID–signed DMG for Jot.
#
# Usage:
#   ./scripts/build-dmg.sh                            # full: sign + notarize + staple
#   VERSION=0.2.0 ./scripts/build-dmg.sh              # override the marketing version
#   SKIP_NOTARIZE=1 ./scripts/build-dmg.sh            # skip step 8 (for visual iteration)
#
# Output:
#   dist/Jot.dmg  (drag-to-Applications layout, Retina-aware background)
#
# SKIP_NOTARIZE=1 is strictly for iterating on the DMG's look. Do NOT ship a
# DMG built that way — it is signed but not stapled, so first-run Gatekeeper
# will flag it on machines without network access.

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

# DMG look & feel assets (see Resources/).
DMG_BG_1X="${REPO_ROOT}/Resources/dmg-background.png"
DMG_BG_2X="${REPO_ROOT}/Resources/dmg-background@2x.png"
APP_ICON_1024="${REPO_ROOT}/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"

# DMG Finder window geometry (points).
DMG_WINDOW_W=640
DMG_WINDOW_H=400
DMG_ICON_SIZE=128
DMG_ICON_Y=210         # vertical center of icons (matches arrow in bg)
DMG_APP_X=180          # Jot.app icon center x — inner edge at 244, matches bg arrow start
DMG_APPLINK_X=460      # Applications symlink icon center x — inner edge at 396, matches bg arrow end

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

DMG_NAME="Jot.dmg"
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
# Flavor builds can inject extra Swift flags (e.g. `-DJOT_FLAVOR_1`) via
# `JOT_EXTRA_SWIFT_FLAGS` sourced from `.flavor-*.env`. Public builds leave
# the env var unset, so OTHER_SWIFT_FLAGS is not forwarded and the archive
# is byte-identical to today.
ARCHIVE_EXTRA_ARGS=()
if [[ -n "${JOT_EXTRA_SWIFT_FLAGS:-}" ]]; then
    log "Threading JOT_EXTRA_SWIFT_FLAGS into archive: ${JOT_EXTRA_SWIFT_FLAGS}"
    ARCHIVE_EXTRA_ARGS+=("OTHER_SWIFT_FLAGS=\$(inherited) ${JOT_EXTRA_SWIFT_FLAGS}")
fi

log "Archiving ${SCHEME} (${CONFIGURATION}, arm64)"
xcodebuild \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination 'platform=macOS,arch=arm64' \
    -archivePath "${ARCHIVE_PATH}" \
    "${ARCHIVE_EXTRA_ARGS[@]}" \
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
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Vineet Sriram (8VB2ULDN22)}"
log "Signing with: ${SIGN_IDENTITY}"
codesign \
    --force \
    --sign "${SIGN_IDENTITY}" \
    --options runtime \
    --entitlements "${ENTITLEMENTS_PATH}" \
    "${APP_PATH}"

# -----------------------------------------------------------------------------
# 6. Verify signature + Gatekeeper assessment
# -----------------------------------------------------------------------------
log "codesign --verify:"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}" 2>&1 || \
    fail "codesign verification failed"

log "spctl assessment:"
set +e
SPCTL_OUTPUT="$(spctl -a -vv -t install "${APP_PATH}" 2>&1)"
SPCTL_EXIT=$?
set -e
printf '%s\n' "${SPCTL_OUTPUT}"
if [[ ${SPCTL_EXIT} -ne 0 ]]; then
    warn "spctl rejected the app. If signed with Developer ID, notarization may be needed."
fi

# -----------------------------------------------------------------------------
# 7. Build the DMG (drag-to-Applications layout with branded background)
# -----------------------------------------------------------------------------
STAGING_DIR="${BUILD_DIR}/dmg-staging"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"
log "Staging DMG contents in ${STAGING_DIR}"
cp -R "${APP_PATH}" "${STAGING_DIR}/Jot.app"
ln -s /Applications "${STAGING_DIR}/Applications"

# Copy the background image into a hidden dir inside the staging area so Finder
# can reference it after mount. Both 1x and 2x live side-by-side; the 2x copy
# (named `background.tiff`) is what Finder prefers for Retina rendering.
BG_STAGE_DIR="${STAGING_DIR}/.background"
mkdir -p "${BG_STAGE_DIR}"
if [[ -f "${DMG_BG_1X}" && -f "${DMG_BG_2X}" ]]; then
    # Combine 1x + 2x into a multi-resolution TIFF — Finder picks the right one.
    if command -v tiffutil >/dev/null 2>&1; then
        tiffutil -cathidpicheck "${DMG_BG_1X}" "${DMG_BG_2X}" \
            -out "${BG_STAGE_DIR}/background.tiff" >/dev/null 2>&1 || \
            cp "${DMG_BG_2X}" "${BG_STAGE_DIR}/background.tiff"
    else
        cp "${DMG_BG_2X}" "${BG_STAGE_DIR}/background.tiff"
    fi
    # Keep a PNG copy too — some scripts / older Finders are happier with PNG.
    cp "${DMG_BG_2X}" "${BG_STAGE_DIR}/background.png"
    HAVE_BACKGROUND=1
else
    warn "DMG background images missing under Resources/ — building plain DMG."
    HAVE_BACKGROUND=0
fi

# Optional: volume icon derived from the app icon (512×512 .icns).
VOLICON_PATH=""
if [[ -f "${APP_ICON_1024}" ]] && command -v iconutil >/dev/null 2>&1; then
    VOLICONSET_DIR="${BUILD_DIR}/VolumeIcon.iconset"
    rm -rf "${VOLICONSET_DIR}"
    mkdir -p "${VOLICONSET_DIR}"
    # Minimal set: macOS actually just needs icon_512x512 + @2x for a clean look,
    # but we include the common sizes so the volume icon scales everywhere.
    sips -s format png -z 16   16   "${APP_ICON_1024}" --out "${VOLICONSET_DIR}/icon_16x16.png"      >/dev/null
    sips -s format png -z 32   32   "${APP_ICON_1024}" --out "${VOLICONSET_DIR}/icon_16x16@2x.png"   >/dev/null
    sips -s format png -z 32   32   "${APP_ICON_1024}" --out "${VOLICONSET_DIR}/icon_32x32.png"      >/dev/null
    sips -s format png -z 64   64   "${APP_ICON_1024}" --out "${VOLICONSET_DIR}/icon_32x32@2x.png"   >/dev/null
    sips -s format png -z 128  128  "${APP_ICON_1024}" --out "${VOLICONSET_DIR}/icon_128x128.png"    >/dev/null
    sips -s format png -z 256  256  "${APP_ICON_1024}" --out "${VOLICONSET_DIR}/icon_128x128@2x.png" >/dev/null
    sips -s format png -z 256  256  "${APP_ICON_1024}" --out "${VOLICONSET_DIR}/icon_256x256.png"    >/dev/null
    sips -s format png -z 512  512  "${APP_ICON_1024}" --out "${VOLICONSET_DIR}/icon_256x256@2x.png" >/dev/null
    sips -s format png -z 512  512  "${APP_ICON_1024}" --out "${VOLICONSET_DIR}/icon_512x512.png"    >/dev/null
    cp "${APP_ICON_1024}"                                    "${VOLICONSET_DIR}/icon_512x512@2x.png"
    if iconutil -c icns "${VOLICONSET_DIR}" -o "${BUILD_DIR}/VolumeIcon.icns" 2>/dev/null; then
        VOLICON_PATH="${BUILD_DIR}/VolumeIcon.icns"
    else
        warn "iconutil failed; volume icon will fall back to the default."
    fi
fi

if command -v dmgbuild >/dev/null 2>&1; then
    log "Using dmgbuild (pure Python, no AppleScript / no TCC prompts)"
    DMG_SETTINGS="${SCRIPT_DIR}/dmg-settings.py"
    [[ -f "${DMG_SETTINGS}" ]] || fail "dmgbuild settings missing at ${DMG_SETTINGS}"
    DMGBUILD_ARGS=(
        -s "${DMG_SETTINGS}"
        -D "app=${APP_PATH}"
    )
    [[ ${HAVE_BACKGROUND} -eq 1 ]] && DMGBUILD_ARGS+=(-D "background=${DMG_BG_2X}")
    [[ -n "${VOLICON_PATH}" ]]     && DMGBUILD_ARGS+=(-D "badge_icon=${VOLICON_PATH}")
    rm -f "${DMG_PATH}"
    dmgbuild "${DMGBUILD_ARGS[@]}" "Jot" "${DMG_PATH}"
elif command -v create-dmg >/dev/null 2>&1; then
    log "Using create-dmg (falls back to AppleScript for layout)"
    CREATE_DMG_ARGS=(
        --volname "Jot"
        --window-size "${DMG_WINDOW_W}" "${DMG_WINDOW_H}"
        --icon-size "${DMG_ICON_SIZE}"
        --icon "Jot.app" "${DMG_APP_X}" "${DMG_ICON_Y}"
        --app-drop-link "${DMG_APPLINK_X}" "${DMG_ICON_Y}"
        --hide-extension "Jot.app"
        --no-internet-enable
    )
    [[ ${HAVE_BACKGROUND} -eq 1 ]] && CREATE_DMG_ARGS+=(--background "${DMG_BG_2X}")
    [[ -n "${VOLICON_PATH}" ]]     && CREATE_DMG_ARGS+=(--volicon "${VOLICON_PATH}")
    create-dmg "${CREATE_DMG_ARGS[@]}" "${DMG_PATH}" "${STAGING_DIR}"
else
    log "Neither dmgbuild nor create-dmg installed — falling back to hdiutil + AppleScript"

    # Build a writable DMG first so we can customize the Finder view, then
    # convert to a compressed read-only UDZO image for distribution.
    TEMP_DMG="${BUILD_DIR}/Jot.temp.dmg"
    FINAL_VOLNAME="Jot"

    # Size the sparse image with headroom for the Finder metadata + .DS_Store.
    APP_BYTES="$(du -sk "${STAGING_DIR}" | awk '{print $1}')"
    DMG_SIZE_KB=$(( APP_BYTES + 20480 ))  # ~20 MB of slack

    rm -f "${TEMP_DMG}"
    hdiutil create \
        -srcfolder "${STAGING_DIR}" \
        -volname "${FINAL_VOLNAME}" \
        -fs HFS+ \
        -format UDRW \
        -size "${DMG_SIZE_KB}k" \
        "${TEMP_DMG}" >/dev/null

    # Mount it (skip Spotlight / Trash clutter).
    MOUNT_ROOT="${BUILD_DIR}/dmg-mount"
    rm -rf "${MOUNT_ROOT}"
    mkdir -p "${MOUNT_ROOT}"
    MOUNT_DIR="${MOUNT_ROOT}/${FINAL_VOLNAME}"
    hdiutil attach "${TEMP_DMG}" \
        -mountpoint "${MOUNT_DIR}" \
        -nobrowse -noautoopen >/dev/null

    # Install the volume icon, if we built one.
    if [[ -n "${VOLICON_PATH}" ]]; then
        cp "${VOLICON_PATH}" "${MOUNT_DIR}/.VolumeIcon.icns"
        # The `has custom icon` attribute is what tells Finder to use it.
        SetFile -a C "${MOUNT_DIR}" 2>/dev/null || true
    fi

    # Drive Finder via AppleScript to set window size, icon positions,
    # background image, and hide the sidebar + toolbar. We retry a couple
    # times because Finder occasionally needs a beat to notice the new volume.
    if [[ ${HAVE_BACKGROUND} -eq 1 ]]; then
        BG_REF='set background picture of theViewOptions to file ".background:background.tiff"'
    else
        BG_REF=''
    fi

    # First time this runs from a new terminal, macOS will prompt for
    # Automation → Finder permission. If that prompt is denied (or was never
    # answered), osascript exits with -1743 and the DMG ships with the
    # default Finder view instead of the custom layout. The DMG is still
    # valid; just visually plain. Re-grant permission in
    # System Settings → Privacy & Security → Automation → <your terminal>.
    APPLESCRIPT_OK=1
    /usr/bin/osascript <<APPLESCRIPT 2>/tmp/jot-dmg-osascript.err || APPLESCRIPT_OK=0
tell application "Finder"
    tell disk "${FINAL_VOLNAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set sidebar width of container window to 0
        set the bounds of container window to {200, 150, ${DMG_WINDOW_W} + 200, ${DMG_WINDOW_H} + 150}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to ${DMG_ICON_SIZE}
        set text size of theViewOptions to 13
        ${BG_REF}
        set position of item "Jot.app" of container window to {${DMG_APP_X}, ${DMG_ICON_Y}}
        set position of item "Applications" of container window to {${DMG_APPLINK_X}, ${DMG_ICON_Y}}
        update without registering applications
        close
    end tell
end tell
APPLESCRIPT

    if [[ ${APPLESCRIPT_OK} -ne 1 ]]; then
        warn "AppleScript layout failed. DMG will mount with Finder's default view."
        warn "Cause: $(cat /tmp/jot-dmg-osascript.err 2>/dev/null | head -1)"
        warn "Fix:   grant your terminal Automation → Finder access in"
        warn "       System Settings → Privacy & Security → Automation, then re-run."
    fi

    # Let Finder flush the .DS_Store before we detach.
    sync
    sleep 2

    hdiutil detach "${MOUNT_DIR}" -quiet || hdiutil detach "${MOUNT_DIR}" -force -quiet

    # Convert to the final compressed, read-only UDZO image.
    rm -f "${DMG_PATH}"
    hdiutil convert "${TEMP_DMG}" \
        -format UDZO \
        -imagekey zlib-level=9 \
        -o "${DMG_PATH}" >/dev/null
    rm -f "${TEMP_DMG}"
    rm -rf "${MOUNT_ROOT}"
fi

[[ -f "${DMG_PATH}" ]] || fail "DMG was not produced at ${DMG_PATH}"

# -----------------------------------------------------------------------------
# 8. Notarize + staple  (skip with SKIP_NOTARIZE=1 for fast visual iteration)
# -----------------------------------------------------------------------------
if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
    warn "SKIP_NOTARIZE=1 set — skipping notarization + stapling."
    warn "DO NOT ship this DMG. It is for local visual iteration only."
else
    NOTARY_PROFILE="${NOTARY_PROFILE:-Jot}"
    log "Submitting DMG to Apple for notarization (profile: ${NOTARY_PROFILE})…"
    xcrun notarytool submit "${DMG_PATH}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait

    log "Stapling notarization ticket to DMG"
    xcrun stapler staple "${DMG_PATH}"
fi

# -----------------------------------------------------------------------------
# 9. Verify DMG
# -----------------------------------------------------------------------------
log "Verifying DMG integrity"
hdiutil verify "${DMG_PATH}" >/dev/null

DMG_SIZE="$(du -h "${DMG_PATH}" | awk '{print $1}')"
DMG_SHA256="$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"

# -----------------------------------------------------------------------------
# 10. Summary footer
# -----------------------------------------------------------------------------
cat <<EOF

---------------------------------------------------------------
  Jot DMG build complete
---------------------------------------------------------------
  Version : ${MARKETING_VERSION}
  Path    : ${DMG_PATH}
  Size    : ${DMG_SIZE}
  SHA-256 : ${DMG_SHA256}
  Signing : ${SIGN_IDENTITY}
---------------------------------------------------------------
EOF

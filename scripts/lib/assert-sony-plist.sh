#!/usr/bin/env bash
# Assert that an Info.plist has been correctly Sony-flavored. Run AFTER
# .flavor-sony.overrides has been applied, BEFORE build-dmg.sh, so a
# malformed or partially-applied overrides file gets caught before a
# bad DMG is built and shipped.
#
# Catches the inverse of the v1.8 leak: a Sony release that ships with
# public values because the overrides file was empty / typo'd / failed
# to apply.
#
# Usage:
#   scripts/lib/assert-sony-plist.sh Resources/Info.plist
set -euo pipefail

PLIST="${1:?Usage: $0 <path-to-plist>}"
[[ -f "$PLIST" ]] || { echo "[assert-sony-plist] ERROR: plist not found: $PLIST" >&2; exit 1; }

fail() {
    printf "\033[1;31m[assert-sony-plist]\033[0m MISSING: %s\n" "$*" >&2
    exit 1
}

# 1. JotFlavor must be 'sony'.
jot_flavor="$(/usr/libexec/PlistBuddy -c "Print :JotFlavor" "$PLIST" 2>/dev/null || echo '')"
[[ "$jot_flavor" == "sony" ]] \
    || fail "JotFlavor='${jot_flavor:-<absent>}', expected 'sony'"

# 2. SUFeedURL must point at a recognized Sony-internal anonymous-readable host.
#    - github.sie.sony.com — legacy (requires SSO; Sparkle can't fetch anonymously)
#    - kcloud.playstation.net — Simple Host (current; anonymous, no SSO)
su_feed="$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$PLIST" 2>/dev/null || echo '')"
[[ "$su_feed" == *"github.sie.sony.com"* || "$su_feed" == *"kcloud.playstation.net"* ]] \
    || fail "SUFeedURL='${su_feed:-<absent>}' doesn't point at a recognized Sony host"

# 3. PlayStation gateway endpoint must be present in at least one value.
grep -q "gateway.ai.studios.playstation.com" "$PLIST" \
    || fail "No playstation gateway endpoint values present — .flavor-sony.overrides may have failed to apply"

# 4. PFB Enterprise (FLAVOR_1_DISPLAY_NAME) marker key must be set.
grep -q "<key>FLAVOR_1_DISPLAY_NAME" "$PLIST" \
    || fail "FLAVOR_1_DISPLAY_NAME key missing — .flavor-sony.overrides may have failed to apply"

printf "[assert-sony-plist] valid: %s (flavor=sony, SUFeedURL=%s)\n" "$PLIST" "$su_feed"

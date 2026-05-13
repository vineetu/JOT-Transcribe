#!/usr/bin/env bash
# Assert that an Info.plist is in a clean public-release state — no
# Sony-flavor keys, no Sony-host substrings, JotFlavor=public if set.
#
# Designed to be a precondition gate for the public release path. Catches
# the v1.8 leak class: any Sony override left in Info.plist from manual
# testing or a botched flavor-restore must fail loudly here, not after
# the public DMG has been built and tagged.
#
# Usage:
#   scripts/lib/assert-public-plist.sh Resources/Info.plist
set -euo pipefail

PLIST="${1:?Usage: $0 <path-to-plist>}"
[[ -f "$PLIST" ]] || { echo "[assert-public-plist] ERROR: plist not found: $PLIST" >&2; exit 1; }

fail() {
    printf "\033[1;31m[assert-public-plist]\033[0m LEAK: %s\n" "$*" >&2
    printf "  Run 'git diff -- %s' to inspect.\n" "$PLIST" >&2
    exit 1
}

# 1. JotFlavor must be 'public' or absent.
if jot_flavor="$(/usr/libexec/PlistBuddy -c "Print :JotFlavor" "$PLIST" 2>/dev/null)"; then
    if [[ "$jot_flavor" != "public" ]]; then
        fail "JotFlavor='${jot_flavor}', expected 'public' or absent"
    fi
fi

# 2. No FLAVOR_1_* keys (Sony build activates a #if JOT_FLAVOR_1 path
#    that reads these). Public Info.plist has none.
if grep -q "<key>FLAVOR_1_" "$PLIST"; then
    fail "FLAVOR_1_* keys present (Sony-only)"
fi

# 3. No JotDefaultEndpoint.* / JotDefaultModel.* keys. Public uses the
#    library defaults; only flavor overrides write these.
if grep -q -E "<key>JotDefault(Endpoint|Model)\." "$PLIST"; then
    fail "JotDefaultEndpoint.* / JotDefaultModel.* keys present (Sony override territory)"
fi

# 4. No Sony hostname substrings in any value. These are the exact
#    strings users reported visible in the v1.8 DMG's leaked Info.plist.
for needle in \
    "gateway.ai.studios.playstation.com" \
    "github.sie.sony.com" \
    "ai-gateway.dspprod.bis.sie.sony.com" \
    "ai-gateway.dspprod.bis"; do
    if grep -q "$needle" "$PLIST"; then
        fail "Sony hostname substring present: '$needle'"
    fi
done

# 5. SUFeedURL must point at the public repo when it's present.
if su_feed="$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$PLIST" 2>/dev/null)"; then
    if [[ "$su_feed" != *"vineetu/JOT-Transcribe"* ]]; then
        fail "SUFeedURL='${su_feed}' doesn't point at the public repo"
    fi
fi

printf "[assert-public-plist] clean: %s\n" "$PLIST"

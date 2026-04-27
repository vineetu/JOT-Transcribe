#!/usr/bin/env bash
# One-command verification gate for the agentic-testing roadmap.
#
# Usage:
#   ./scripts/agent-verify.sh <tier>
#
# Tiers (per docs/plans/agentic-testing.md §"Tiers"):
#   1  (~2 min)   Default xcodebuild build + strict-concurrency build
#                 (warning count ≤ baseline) + JotTests unit suite.
#   2  (~5 min)   Tier 1 + the harness flow tests (dictate happy-path,
#                 articulate fixed/custom + I2 known-issue, askJotVoice
#                 happy/short/I1 known-issue, runWizard).
#   3  (~10 min)  Tier 2 + a TSan-instrumented re-run of the harness
#                 flow tests. Snapshot tests are not yet wired (Phase 1
#                 doesn't ship any) so this tier currently equals tier 2
#                 plus TSan.
#
# An agent runs `./scripts/agent-verify.sh 2` before claiming any non-
# trivial refactor done. The script prints a per-stage banner, captures
# stage failures, and exits non-zero with a summary on the first stage
# that fails. Re-running with the same tier on a clean tree is
# idempotent.
#
# Strict-concurrency baseline is 250 raw warnings (was 254 before
# Phase 0; came down 4 from genuine fixes). Override via:
#   STRICT_CONCURRENCY_BASELINE=251 ./scripts/agent-verify.sh 1

set -uo pipefail

readonly TIER="${1:-}"
if [[ -z "$TIER" ]]; then
    cat <<EOF >&2
usage: $0 <tier>
  tier 1  (~2m)   default build + strict-concurrency + JotTests
  tier 2  (~5m)   tier 1 + harness flow tests
  tier 3  (~10m)  tier 2 + TSan
EOF
    exit 64  # EX_USAGE
fi

# Locate repo root from the script path so the script works no matter
# where it's invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------

readonly STRICT_CONCURRENCY_BASELINE="${STRICT_CONCURRENCY_BASELINE:-250}"
readonly XCODEBUILD_DESTINATION="platform=macOS"
readonly LOG_DIR="$REPO_ROOT/.agent-verify-logs"
mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

stage() {
    local name="$1"
    printf '\n\033[1;36m[agent-verify] %s\033[0m\n' "$name"
}

fail() {
    local name="$1"
    local logfile="$2"
    printf '\n\033[1;31m[agent-verify] FAIL: %s\033[0m\n' "$name" >&2
    printf '  log: %s\n' "$logfile" >&2
    if [[ -f "$logfile" ]]; then
        printf '  last 30 lines:\n' >&2
        tail -30 "$logfile" >&2
    fi
    exit 1
}

ok() {
    local name="$1"
    printf '\033[1;32m[agent-verify] OK: %s\033[0m\n' "$name"
}

# ---------------------------------------------------------------------
# Stage: default build
# ---------------------------------------------------------------------

stage_default_build() {
    stage "default xcodebuild build (Debug)"
    local log="$LOG_DIR/default-build.log"
    if xcodebuild -scheme Jot \
        -project Jot.xcodeproj \
        -destination "$XCODEBUILD_DESTINATION" \
        -configuration Debug \
        build > "$log" 2>&1; then
        ok "default build"
    else
        fail "default build" "$log"
    fi
}

# ---------------------------------------------------------------------
# Stage: strict-concurrency build (warning-count gate)
# ---------------------------------------------------------------------

stage_strict_concurrency() {
    stage "strict-concurrency build (baseline ≤ ${STRICT_CONCURRENCY_BASELINE})"
    local log="$LOG_DIR/strict-concurrency.log"
    # Clean build so warning count is deterministic — incremental
    # builds only re-emit warnings for files that changed, which would
    # under-report the baseline.
    #
    # Phase 3 #12: this stage measures strict-concurrency progress
    # toward 0, not a hard build gate. The Jot target's
    # `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES` is overridden here
    # (`= NO`) so the 71 unique strict-concurrency warning sites stay
    # warnings, not errors. The default build stage above is the
    # actual warnings-as-errors gate.
    xcodebuild -scheme Jot \
        -project Jot.xcodeproj \
        -destination "$XCODEBUILD_DESTINATION" \
        -configuration Debug \
        clean build \
        OTHER_SWIFT_FLAGS='$(inherited) -strict-concurrency=complete' \
        SWIFT_TREAT_WARNINGS_AS_ERRORS=NO \
        > "$log" 2>&1
    local rc=$?

    if (( rc != 0 )); then
        # Distinguish warning-count regression from a real build break.
        if grep -q ': error:' "$log"; then
            fail "strict-concurrency build (errors)" "$log"
        fi
    fi

    # Count UNIQUE warning sites (dedupe by `file:line:col`) — raw
    # count includes per-incremental-batch duplicates and varies with
    # the build cache state. Phase 0 reduced the unique baseline from
    # 254 to 250.
    local count
    count="$(grep -E ': warning:' "$log" \
        | awk -F': warning:' '{print $1}' \
        | sort -u \
        | wc -l \
        | tr -d ' ')"
    printf '  unique warning sites: %s (baseline %s)\n' "$count" "$STRICT_CONCURRENCY_BASELINE"
    if (( count > STRICT_CONCURRENCY_BASELINE )); then
        printf '\n\033[1;31m[agent-verify] strict-concurrency regression: %s > %s\033[0m\n' \
            "$count" "$STRICT_CONCURRENCY_BASELINE" >&2
        printf '  log: %s\n' "$log" >&2
        exit 1
    fi
    ok "strict-concurrency (unique sites=$count)"
}

# ---------------------------------------------------------------------
# Stage: JotTests unit suite
# ---------------------------------------------------------------------

stage_unit_tests() {
    stage "JotTests unit suite"
    local log="$LOG_DIR/jot-tests.log"
    if xcodebuild test -scheme Jot \
        -project Jot.xcodeproj \
        -destination "$XCODEBUILD_DESTINATION" \
        -only-testing:JotTests \
        > "$log" 2>&1; then
        ok "JotTests"
    else
        fail "JotTests" "$log"
    fi
}

# ---------------------------------------------------------------------
# Stage: harness flow tests (subset of JotTests — explicit selection)
# ---------------------------------------------------------------------

stage_harness_flows() {
    stage "harness flow tests (dictate / articulate / askJot / wizard)"
    local log="$LOG_DIR/harness-flows.log"
    # Each flow suite is `.serialized` already; running them via
    # `-only-testing` keeps the harness gate active across them. We
    # invoke each suite's bundle name explicitly so a future suite
    # rename surfaces as a clean failure instead of silent skip.
    if xcodebuild test -scheme Jot \
        -project Jot.xcodeproj \
        -destination "$XCODEBUILD_DESTINATION" \
        -only-testing:JotTests/DictateFlowTests \
        -only-testing:JotTests/ArticulateFlowTests \
        -only-testing:JotTests/AskJotFlowTests \
        -only-testing:JotTests/WizardFlowTests \
        > "$log" 2>&1; then
        ok "harness flow tests"
    else
        fail "harness flow tests" "$log"
    fi
}

# ---------------------------------------------------------------------
# Stage: TSan re-run (tier 3 only)
# ---------------------------------------------------------------------

stage_tsan() {
    stage "TSan-instrumented harness flow re-run"
    local log="$LOG_DIR/tsan.log"
    # `-enableThreadSanitizer YES` instruments the test runner.
    # TSan adds noticeable overhead; keep this tier-3 only.
    if xcodebuild test -scheme Jot \
        -project Jot.xcodeproj \
        -destination "$XCODEBUILD_DESTINATION" \
        -enableThreadSanitizer YES \
        -only-testing:JotTests/DictateFlowTests \
        -only-testing:JotTests/ArticulateFlowTests \
        -only-testing:JotTests/AskJotFlowTests \
        -only-testing:JotTests/WizardFlowTests \
        > "$log" 2>&1; then
        ok "TSan run"
    else
        fail "TSan run" "$log"
    fi
}

# ---------------------------------------------------------------------
# Tier dispatch
# ---------------------------------------------------------------------

case "$TIER" in
    1)
        stage_default_build
        stage_strict_concurrency
        stage_unit_tests
        ;;
    2)
        stage_default_build
        stage_strict_concurrency
        stage_unit_tests
        stage_harness_flows
        ;;
    3)
        stage_default_build
        stage_strict_concurrency
        stage_unit_tests
        stage_harness_flows
        stage_tsan
        ;;
    *)
        printf 'unknown tier: %s (expected 1, 2, or 3)\n' "$TIER" >&2
        exit 64
        ;;
esac

printf '\n\033[1;32m[agent-verify] tier %s passed\033[0m\n' "$TIER"

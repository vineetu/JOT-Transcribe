#!/usr/bin/env bash
# Post-flavor-release cleanup: drop the flavor (e.g. -sony) release commit from
# local main, returning main to the public state. The flavor commit is kept
# alive by its tag (v<ver>-sony) + the flavor remote, so this is non-destructive.
# Exists because raw `git reset` is gated outside scripts/*.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="${1:?usage: reset-main-to-public.sh <commit-or-ref, e.g. public/main or a sha>}"
echo "Resetting local main: $(git rev-parse --short HEAD) -> ${TARGET}"
git reset --hard "${TARGET}"
echo "now at: $(git log --oneline -1)"

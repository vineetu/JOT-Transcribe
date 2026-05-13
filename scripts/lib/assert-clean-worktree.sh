#!/usr/bin/env bash
# Assert that one or more tracked paths have no uncommitted modifications.
#
# Root-cause guard for the v1.8 Sony leak: manual `xcodebuild archive`
# testing mutated Resources/Info.plist with Sony overrides and forgot
# to restore. The next public release captured the tainted plist in
# its commit and shipped Sony URLs to public users. A `git diff --quiet`
# on Info.plist before release would have caught this immediately.
#
# Usage:
#   scripts/lib/assert-clean-worktree.sh Resources/Info.plist [more paths...]
set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "[assert-clean-worktree] Usage: $0 <path> [<path>...]" >&2
    exit 2
fi

for path in "$@"; do
    if ! git diff --quiet -- "$path"; then
        printf "\033[1;31m[assert-clean-worktree]\033[0m DIRTY: %s has uncommitted changes.\n" "$path" >&2
        printf "  Inspect with: git diff -- %s\n" "$path" >&2
        printf "  Resolve with: git checkout -- %s   (or commit it before releasing)\n" "$path" >&2
        exit 1
    fi
    # Also check the staged area — a staged-but-uncommitted change is
    # just as dangerous as an unstaged one for the next commit.
    if ! git diff --cached --quiet -- "$path"; then
        printf "\033[1;31m[assert-clean-worktree]\033[0m STAGED: %s has uncommitted staged changes.\n" "$path" >&2
        printf "  Inspect with: git diff --cached -- %s\n" "$path" >&2
        exit 1
    fi
done

printf "[assert-clean-worktree] clean: %s\n" "$*"

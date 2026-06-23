#!/usr/bin/env bash
# Land an ALREADY-BUILT public release onto public/main without rebuilding,
# surviving the marketing auto-pusher's fast-forward race. Rebases local main
# onto the latest public/main; the ONLY expected conflict is README.md (the
# auto-pusher's marketing rewrite vs our macOS-version bump) — resolved by
# KEEPING the auto-pusher's README and re-applying only the macOS 14->15 bump,
# so no marketing/website work is overwritten. Any OTHER conflict aborts.
set -euo pipefail
cd "$(dirname "$0")/.."
REMOTE=public
TAG="${1:?usage: land-public-release.sh vX.Y}"

resolve_readme_only() {
  # While a rebase is mid-conflict, auto-resolve iff README.md is the ONLY
  # conflicted path; otherwise bail loudly.
  while [[ -d .git/rebase-merge || -d .git/rebase-apply ]]; do
    local conflicts
    conflicts="$(git diff --name-only --diff-filter=U | sort -u)"
    if [[ "$conflicts" == "README.md" ]]; then
      git checkout --ours README.md                 # ours == public/main base (auto-pusher's README)
      perl -i -pe 's/\bmacOS 14\+/macOS 15+/g; s/macOS Sonoma 14\.0 or later/macOS Sequoia 15.0 or later/g; s/Sonoma 14\.0/Sequoia 15.0/g' README.md
      git add README.md
      GIT_EDITOR=true git rebase --continue
    elif [[ -z "$conflicts" ]]; then
      GIT_EDITOR=true git rebase --continue   # nothing to resolve at this step
    else
      echo "[land] UNEXPECTED conflicts (not README-only): $conflicts" >&2
      git rebase --abort || true
      exit 2
    fi
  done
}

for attempt in 1 2 3 4 5; do
  echo "[land] attempt $attempt"
  git fetch "$REMOTE"
  if ! git rebase "$REMOTE/main"; then
    resolve_readme_only
  fi
  git tag -f "$TAG" HEAD
  if git push "$REMOTE" HEAD:main && git push -f "$REMOTE" "$TAG"; then
    echo "[land] PUSHED main + $TAG to $REMOTE"
    exit 0
  fi
  echo "[land] push rejected (race) — refetch + retry"
  sleep 5
done
echo "[land] FAILED after retries" >&2; exit 1

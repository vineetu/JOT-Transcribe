#!/usr/bin/env bash
# Push local main to public/main, surviving the marketing auto-pusher's
# fast-forward race (rebase onto latest public/main, then push, retrying).
# For NON-release commits (no tag move) — releases use land-public-release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
REMOTE=public
for attempt in 1 2 3 4 5; do
  echo "[push] attempt $attempt"
  git fetch "$REMOTE"
  if ! git rebase "$REMOTE/main"; then
    git rebase --abort || true
    echo "[push] rebase conflict — manual intervention needed" >&2
    exit 2
  fi
  if git push "$REMOTE" HEAD:main; then
    echo "[push] PUSHED main to $REMOTE"
    exit 0
  fi
  echo "[push] race — refetch + retry"
  sleep 5
done
echo "[push] FAILED after retries" >&2; exit 1

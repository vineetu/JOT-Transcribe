#!/usr/bin/env bash
# ONE-OFF remediation: replace a just-pushed public release commit whose tree
# accidentally included files that must not be in the public repo, before it
# is widely fetched. Rewrites public/main to the current (amended) HEAD and
# moves the release tag to match. Refuses to run unless HEAD is a "Release"
# commit and the working tree is clean — this is not a general-purpose pusher.
#
# Usage: force-replace-public-release.sh <tag, e.g. v1.17.5>
set -euo pipefail
cd "$(dirname "$0")/.."
REMOTE=public
TAG="${1:?usage: force-replace-public-release.sh vX.Y.Z}"

git log -1 --format=%s | grep -q '^Release ' || { echo "HEAD is not a release commit" >&2; exit 2; }
[[ -z "$(git status --porcelain | grep -v '^??')" ]] || { echo "working tree not clean" >&2; exit 2; }

git fetch "$REMOTE"
echo "[replace] public/main is $(git rev-parse --short "$REMOTE/main"); replacing with $(git rev-parse --short HEAD)"
git push --force-with-lease="main:$(git rev-parse "$REMOTE/main")" "$REMOTE" HEAD:main
git tag -f "$TAG" HEAD
git push -f "$REMOTE" "$TAG"
echo "[replace] done: main + $TAG now at $(git rev-parse --short HEAD)"

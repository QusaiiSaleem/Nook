#!/bin/bash
# Fork/update.sh: bring in the newest official Nook release, keep the fork's changes, rebuild.
#
#   Fork/update.sh            -> merge the newest official release tag, test, build, install
#   Fork/update.sh --check    -> only say whether a newer official release exists
#
# Steps: fetch upstream tags -> merge the newest vX.Y.Z (no betas) into the current branch ->
# run the tab model tests -> Fork/build.sh --install. A merge conflict stops before anything
# is built; `git merge --abort` puts the branch back exactly as it was.
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SRC"

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "Uncommitted changes in $SRC; commit or stash them first." >&2
  exit 1
fi

git fetch --quiet --tags upstream
LATEST="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | grep -v -- '-' | head -1)"
if git merge-base --is-ancestor "$LATEST" HEAD; then
  echo "Up to date: $LATEST is already in $(git rev-parse --abbrev-ref HEAD)."
  exit 0
fi
echo "Newer official release: $LATEST"
[ "${1:-}" = "--check" ] && exit 0

BEFORE="$(git rev-parse HEAD)"
if ! git merge --no-edit -m "Merge official release $LATEST" "$LATEST"; then
  echo "Merge conflict with $LATEST. Nothing was built. Undo with: git merge --abort" >&2
  exit 1
fi

if ! (cd Packages/NookTabsCore && swift test >/dev/null); then
  echo "Tab model tests failed after merging $LATEST. Undo with: git reset --hard $BEFORE" >&2
  exit 1
fi

"$SRC/Fork/build.sh" --install
echo "Updated to $LATEST and installed. Push with: git push origin $(git rev-parse --abbrev-ref HEAD)"

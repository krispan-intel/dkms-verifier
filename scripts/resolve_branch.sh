#!/usr/bin/env bash
# Map a branch name to (TAG, BASE, HEAD) for run_release.sh.
#
# Usage: resolve_branch.sh <kernel-src> <branch>
#
# Strategy:
#   HEAD  = the commit at <branch>'s tip (resolved to a real SHA).
#   TAG   = the release tag(s) that point at HEAD, filtered by the patterns
#           recognised in scripts/parse_tag.sh:
#               lts-v*-linux-*
#               mainline-preprod-v*-linux-*
#           If multiple tags qualify, the one with the latest YYMMDDTHHMMSSZ
#           timestamp suffix wins.
#   BASE  = derived from TAG via parse_tag.sh.
#
# Prints (one per line, suitable for `eval $(resolve_branch.sh ...)`):
#   TAG=<tag>
#   BASE=<base>
#   HEAD=<commit-sha>
#
# Exits non-zero if no qualifying tag is found at the branch tip — the caller
# can fall back to passing TAG/BASE/HEAD manually.
set -euo pipefail

SRC=${1:?usage: resolve_branch.sh <kernel-src> <branch>}
BRANCH=${2:?branch}
SELF=$(cd "$(dirname "$0")" && pwd)

cd "$SRC"

# Resolve branch to a commit SHA. Accept short refs, full refs, remote refs.
HEAD_SHA=$(git rev-parse --verify "$BRANCH^{commit}" 2>/dev/null) \
  || { echo "ERROR: branch '$BRANCH' not found in $SRC" >&2; exit 2; }

# Find tags pointing at that commit and matching our patterns.
mapfile -t CANDIDATES < <(
  git tag --points-at "$HEAD_SHA" 2>/dev/null \
    | grep -E '^(lts-v[0-9]|mainline-preprod-v[0-9])' \
    || true
)

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  echo "ERROR: no release tag found at $BRANCH ($HEAD_SHA)" >&2
  echo "       expected pattern: lts-v*-linux-* or mainline-preprod-v*-linux-*" >&2
  echo "       hint: push a release tag, or pass --tag/--base/--head manually." >&2
  exit 2
fi

# If multiple match, pick the latest by trailing timestamp.
TAG=$(printf '%s\n' "${CANDIDATES[@]}" \
        | awk '{
            stamp = ""
            if (match($0, /[0-9]{6}T[0-9]{6}Z$/)) stamp = substr($0, RSTART, RLENGTH)
            print stamp "\t" $0
          }' \
        | sort -r \
        | head -1 \
        | cut -f2-)

eval "$("$SELF/parse_tag.sh" "$TAG")"

echo "TAG=$TAG"
echo "BASE=$BASE"
echo "HEAD=$HEAD_SHA"

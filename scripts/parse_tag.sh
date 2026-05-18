#!/usr/bin/env bash
# Extract the OOT baseline from a release tag.
#
# Tag conventions supported:
#   lts-v6.18.27-linux-260507T092754Z          → BASE=v6.18.27
#   mainline-preprod-v7.0-linux-260513T080332Z → BASE=v7.0
#
# Usage: parse_tag.sh <tag>
# Prints:
#   BASE=<git-tag-or-rev>
#   STREAM=<lts|mainline-preprod|...>
#   STAMP=<YYMMDDTHHMMSSZ>
set -euo pipefail

TAG=${1:?usage: parse_tag.sh <tag>}

# Pull the v<...> token (must start with v + digit).
BASE=$(echo "$TAG" | grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)
[[ -n "$BASE" ]] || { echo "ERROR: cannot extract version from tag: $TAG" >&2; exit 2; }

# Stream is everything before the first -v<digit>.
STREAM=$(echo "$TAG" | sed -E 's/-v[0-9].*//')

# Timestamp is the trailing -<YYMMDDTHHMMSSZ>.
STAMP=$(echo "$TAG" | grep -oE '[0-9]{6}T[0-9]{6}Z' || echo "")

echo "BASE=$BASE"
echo "STREAM=$STREAM"
echo "STAMP=$STAMP"

#!/usr/bin/env bash
# Stage every Ubuntu KMI baseline listed in targets.conf into targets/<id>/staged/.
# Idempotent — skips a target if Module.symvers is already cached.
#
# Usage: refresh_targets.sh [--force]
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONF="$ROOT/targets.conf"
FORCE=${1:-}

[[ -f "$CONF" ]] || { echo "ERROR: $CONF missing" >&2; exit 2; }

while IFS=$'\t ' read -r id ver rest; do
  [[ -z "$id" || "$id" =~ ^# ]] && continue
  ver=$(echo "$ver" | awk '{print $1}')

  staged="$ROOT/targets/$id/staged"
  if [[ -f "$staged/Module.symvers" && "$FORCE" != "--force" ]]; then
    echo "[skip] $id ($ver) already staged"
    continue
  fi

  echo "[fetch] $id → kernel $ver"
  rm -rf "$ROOT/targets/$id"
  "$ROOT/fetch_ubuntu_kernel.sh" "$ver" "$ROOT/targets/$id"
done < <(grep -vE '^[[:space:]]*(#|$)' "$CONF")

echo
echo "Cached targets:"
for d in "$ROOT"/targets/*/staged; do
  [[ -d "$d" ]] || continue
  id=$(basename "$(dirname "$d")")
  has_v=""; [[ -f "$d/vmlinux" ]] && has_v=" +vmlinux"
  printf "  %-22s symvers=%d lines%s\n" "$id" "$(wc -l <"$d/Module.symvers")" "$has_v"
done

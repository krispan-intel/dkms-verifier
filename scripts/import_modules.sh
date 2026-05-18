#!/usr/bin/env bash
# Stage prebuilt OOT kernel modules from an upstream Jenkins build job.
#
# Accepts the common shapes that kernel build pipelines produce:
#
#   1. A directory containing a /lib/modules/<ver>/kernel/ tree
#      (e.g. unpacked from `make modules_install INSTALL_MOD_PATH=...`)
#   2. A linux-image-*.deb or linux-modules-*.deb
#   3. A .tar / .tar.gz / .tar.zst / .tar.xz of either of the above
#
# Output: a normalised <out>/kernel/ dir suitable to pass as run_release.sh's
# --kmods. Inside it, .ko files keep their kernel-source layout
# (drivers/foo/bar.ko[.{zst,xz}]).
#
# Usage: import_modules.sh <input> <out>
#
# Examples:
#   # Jenkins copyArtifacts dropped a deb in $WORKSPACE/upstream/
#   import_modules.sh upstream/linux-modules-7.0.0-oot1_amd64.deb modules-staged
#
#   # Or a tarball of /lib
#   import_modules.sh upstream/oot-modules.tar.zst modules-staged
#
#   # Or a directory that already has /lib/modules/...
#   import_modules.sh /srv/builds/oot-7.0/INSTALL_MOD_PATH modules-staged
set -euo pipefail

IN=${1:?usage: import_modules.sh <input> <out>}
OUT=${2:?out}

mkdir -p "$OUT"

# Helper: given a directory, find the deepest /lib/modules/<ver>/kernel/ inside
# and symlink/copy it to $OUT/kernel.
finalize_from_dir() {
  local d=$1
  local kdir
  kdir=$(find "$d" -type d -path '*/lib/modules/*/kernel' | head -1)
  [[ -n "$kdir" ]] || { echo "ERROR: no /lib/modules/<ver>/kernel/ found inside $d" >&2; exit 1; }
  echo "  found: $kdir"
  # Keep this simple — copy. Symlinks would point into $TMP for tarball flow.
  rm -rf "$OUT/kernel"
  cp -a "$kdir" "$OUT/kernel"
  # Stash the version too.
  basename "$(dirname "$kdir")" > "$OUT/kernel-version"
  echo "  staged → $OUT/kernel  (version: $(cat "$OUT/kernel-version"))"
}

if [[ -d "$IN" ]]; then
  echo "[import] directory: $IN"
  finalize_from_dir "$IN"
  exit 0
fi

[[ -f "$IN" ]] || { echo "ERROR: $IN not found" >&2; exit 2; }

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT

case "$IN" in
  *.deb|*.ddeb)
    echo "[import] deb: $IN"
    dpkg-deb -x "$IN" "$TMP/extracted"
    finalize_from_dir "$TMP/extracted"
    ;;
  *.tar)
    echo "[import] tar: $IN"
    tar -xf "$IN" -C "$TMP/"
    finalize_from_dir "$TMP/"
    ;;
  *.tar.gz|*.tgz)
    echo "[import] tar.gz: $IN"
    tar -xzf "$IN" -C "$TMP/"
    finalize_from_dir "$TMP/"
    ;;
  *.tar.xz)
    echo "[import] tar.xz: $IN"
    tar -xJf "$IN" -C "$TMP/"
    finalize_from_dir "$TMP/"
    ;;
  *.tar.zst|*.tar.zstd)
    echo "[import] tar.zst: $IN"
    zstd -dc "$IN" | tar -xf - -C "$TMP/"
    finalize_from_dir "$TMP/"
    ;;
  *)
    echo "ERROR: unsupported input type: $IN" >&2
    echo "       supported: directory, .deb, .ddeb, .tar, .tar.gz, .tar.xz, .tar.zst" >&2
    exit 2
    ;;
esac

#!/usr/bin/env bash
# End-to-end pipeline: tag → discover modules → run check_module.sh against
# every target in targets.conf → write summary.csv + analysis/ → build HTML.
#
# Inputs:
#   --tag <release-tag>      Required. Used to derive BASE and to name the output dir.
#   --kernel-src <dir>       Path to the Intel OOT kernel git tree.
#   --kmods <dir>            Where the prebuilt .ko files live for the OOT kernel.
#                            Defaults to /lib/modules/$(uname -r)/kernel — i.e. the
#                            running kernel — useful when running on the build host.
#   --module-artifact <path> Mutually exclusive with --kmods. A deb / tarball /
#                            directory produced by an upstream build job.
#                            Imported via scripts/import_modules.sh into
#                            releases/<tag>/imported/kernel/ and used as --kmods.
#   --base <rev>             Override BASE detection (skip parse_tag.sh).
#   --head <rev>             Override HEAD (default: HEAD of the kernel tree).
#                            Useful when the release is on a branch other than
#                            the currently checked out one.
#   --no-html                Skip HTML generation (just write CSV + analysis).
#
# Output: releases/<tag>/{summary.csv,analysis/,report.html,manifest.txt}
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TAG=""; SRC=""; KMODS=""; ARTIFACT=""; BASE_OVERRIDE=""; HEAD_REV="HEAD"; NO_HTML=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)              TAG=$2; shift 2 ;;
    --kernel-src)       SRC=$2; shift 2 ;;
    --kmods)            KMODS=$2; shift 2 ;;
    --module-artifact)  ARTIFACT=$2; shift 2 ;;
    --base)             BASE_OVERRIDE=$2; shift 2 ;;
    --head)             HEAD_REV=$2; shift 2 ;;
    --no-html)          NO_HTML=1; shift ;;
    -h|--help)          grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$TAG" ]] || { echo "ERROR: --tag required" >&2; exit 2; }
[[ -n "$SRC" ]] || { echo "ERROR: --kernel-src required" >&2; exit 2; }
[[ -d "$SRC/.git" ]] || { echo "ERROR: $SRC is not a git repo" >&2; exit 2; }
[[ -n "$KMODS" && -n "$ARTIFACT" ]] \
  && { echo "ERROR: --kmods and --module-artifact are mutually exclusive" >&2; exit 2; }

# 1. Resolve BASE.
if [[ -n "$BASE_OVERRIDE" ]]; then
  BASE=$BASE_OVERRIDE
else
  eval "$("$ROOT/scripts/parse_tag.sh" "$TAG")"
fi
echo "[$(date +%H:%M:%S)] tag=$TAG base=$BASE head=$HEAD_REV"

# Sanity check: BASE and HEAD exist in the kernel tree.
( cd "$SRC" && git rev-parse --verify "$BASE^{commit}" >/dev/null 2>&1 ) \
  || { echo "ERROR: BASE rev '$BASE' not found in $SRC" >&2; exit 2; }
( cd "$SRC" && git rev-parse --verify "$HEAD_REV^{commit}" >/dev/null 2>&1 ) \
  || { echo "ERROR: HEAD rev '$HEAD_REV' not found in $SRC" >&2; exit 2; }

OUT="$ROOT/releases/$TAG"
mkdir -p "$OUT/analysis"

# 2. Resolve KMODS — either explicit, or import from artifact, or default.
if [[ -n "$ARTIFACT" ]]; then
  echo "[$(date +%H:%M:%S)] importing modules from artifact: $ARTIFACT"
  "$ROOT/scripts/import_modules.sh" "$ARTIFACT" "$OUT/imported"
  KMODS="$OUT/imported/kernel"
fi
KMODS=${KMODS:-/lib/modules/$(uname -r)/kernel}
[[ -d "$KMODS" ]] || { echo "ERROR: kmods dir not found: $KMODS" >&2; exit 2; }
echo "[$(date +%H:%M:%S)] kmods=$KMODS"

# 3. Discover modules from the diff. Pass KMODS so --verify checks against the
# OOT build, not the host's running kernel.
echo "[$(date +%H:%M:%S)] discovering modules ($BASE..$HEAD_REV)"
KMODS_FOR_VERIFY="$KMODS" \
"$ROOT/scripts/discover_modules.sh" "$SRC" "$BASE" "$HEAD_REV" --verify > "$OUT/modules.txt"
n_mods=$(wc -l <"$OUT/modules.txt")
echo "[$(date +%H:%M:%S)]   $n_mods modules to check"

# 3. Targets from config.
mapfile -t TARGETS < <(grep -vE '^[[:space:]]*(#|$)' "$ROOT/targets.conf" | awk '{print $1}')
for tgt in "${TARGETS[@]}"; do
  [[ -f "$ROOT/targets/$tgt/staged/Module.symvers" ]] \
    || { echo "ERROR: target '$tgt' not staged. Run: make refresh-targets" >&2; exit 2; }
done
echo "[$(date +%H:%M:%S)] targets: ${TARGETS[*]}"

# 4. Stage .ko files locally (decompress once).
KO_DIR="$OUT/ko"; mkdir -p "$KO_DIR"
echo "[$(date +%H:%M:%S)] staging .ko files"
while IFS= read -r m; do
  [[ -n "$m" ]] || continue
  alt1=${m//_/-}; alt2=${m//-/_}
  found=$(find "$KMODS" -maxdepth 8 \( \
            -name "$m.ko" -o -name "$m.ko.zst" -o -name "$m.ko.xz" -o \
            -name "$alt1.ko" -o -name "$alt1.ko.zst" -o -name "$alt1.ko.xz" -o \
            -name "$alt2.ko" -o -name "$alt2.ko.zst" -o -name "$alt2.ko.xz" \
          \) 2>/dev/null | head -1)
  [[ -n "$found" ]] || { echo "  miss: $m"; continue; }

  case "$found" in
    *.ko.zst) zstd -df --quiet "$found" -o "$KO_DIR/$m.ko" ;;
    *.ko.xz)  xz -dc "$found" > "$KO_DIR/$m.ko" ;;
    *.ko)     cp "$found" "$KO_DIR/$m.ko" ;;
  esac
done < "$OUT/modules.txt"
echo "[$(date +%H:%M:%S)]   $(ls "$KO_DIR" | wc -l) .ko files staged"

# 5. Run check_module.sh for every (module, target).
echo "module,target,total,missing,real_missing,crc_mismatch,result" > "$OUT/summary.csv"

filter_real_missing() {
  grep -vE '_noprof$|^__ref_stack_chk_guard$|^__fortify_panic$|^__preempt_count$|^const_current_task$' "$1" || true
}

echo "[$(date +%H:%M:%S)] running CRC checks"
for ko in "$KO_DIR"/*.ko; do
  name=$(basename "$ko" .ko)
  for tgt in "${TARGETS[@]}"; do
    rep="$OUT/raw/${name}-vs-${tgt}"
    "$ROOT/check_module.sh" --module "$ko" --target "$ROOT/targets/$tgt/staged" \
      --report "$rep" >/dev/null 2>&1 && rc=0 || rc=$?

    total=$(wc -l < "$rep/used_syms.txt" 2>/dev/null || echo 0)
    miss=$(wc -l  < "$rep/missing_symbols.txt" 2>/dev/null || echo 0)
    crc=$(wc -l   < "$rep/crc_mismatch.txt" 2>/dev/null || echo 0)

    filter_real_missing "$rep/missing_symbols.txt" > "$OUT/analysis/${name}-vs-${tgt}-real-missing.txt"
    real=$(wc -l < "$OUT/analysis/${name}-vs-${tgt}-real-missing.txt")

    res=$([[ $rc -eq 0 ]] && echo PASS || echo FAIL)
    printf "%s,%s,%d,%d,%d,%d,%s\n" "$name" "$tgt" "$total" "$miss" "$real" "$crc" "$res" \
      >> "$OUT/summary.csv"
  done
done
echo "[$(date +%H:%M:%S)] CRC checks done"

# 6. Manifest for traceability.
{
  echo "tag=$TAG"
  echo "base=$BASE"
  echo "head_rev=$HEAD_REV"
  echo "head=$(cd "$SRC" && git rev-parse "$HEAD_REV")"
  echo "kernel_src=$SRC"
  echo "kmods=$KMODS"
  echo "generated_at=$(date -Iseconds)"
  echo "n_modules=$n_mods"
  echo "n_modules_checked=$(ls "$KO_DIR" | wc -l)"
  echo "targets=${TARGETS[*]}"
} > "$OUT/manifest.txt"

# 7. HTML.
if [[ $NO_HTML -eq 0 ]]; then
  echo "[$(date +%H:%M:%S)] building HTML"
  "$ROOT/scripts/build_report.sh" "$OUT" "$TAG"
fi

echo "[$(date +%H:%M:%S)] done → $OUT"

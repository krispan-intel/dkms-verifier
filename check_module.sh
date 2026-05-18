#!/usr/bin/env bash
# Check if a prebuilt kernel module is ABI-compatible with a target kernel.
#
# Two layers:
#   1. CRC check  — compares __versions in the .ko against target Module.symvers.
#                   This is what modprobe/insmod actually enforces.
#   2. kmidiff    — type-level diff of the symbols the module uses, scoped by
#                   a whitelist. Indicates source-level (DKMS) compatibility.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: check_module.sh --module <path.ko> --target <dir> [--my-vmlinux <path>] [--report <dir>]

Required:
  --module <path.ko>      The .ko built against your kernel.
  --target <dir>          Directory containing target kernel artifacts:
                            Module.symvers   (required)
                            vmlinux          (optional, enables kmidiff)

Optional:
  --my-vmlinux <path>     Your kernel's vmlinux. Enables kmidiff together with
                          target/vmlinux.
  --report <dir>          Output directory (default: ./abi-report).

Exit codes:
  0  CRC check passes — module will load.
  1  CRC mismatch or missing symbols — module will fail to load.
  2  Usage / setup error.
EOF
  exit 2
}

MODULE=""
TARGET_DIR=""
MY_VMLINUX=""
REPORT_DIR="./abi-report"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --module)      MODULE=$2; shift 2 ;;
    --target)      TARGET_DIR=$2; shift 2 ;;
    --my-vmlinux)  MY_VMLINUX=$2; shift 2 ;;
    --report)      REPORT_DIR=$2; shift 2 ;;
    -h|--help)     usage ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

[[ -f "$MODULE"     ]] || { echo "ERROR: --module not found: $MODULE" >&2; exit 2; }
[[ -d "$TARGET_DIR" ]] || { echo "ERROR: --target not a dir: $TARGET_DIR" >&2; exit 2; }
TARGET_SYMVERS="$TARGET_DIR/Module.symvers"
[[ -f "$TARGET_SYMVERS" ]] || { echo "ERROR: Module.symvers missing in $TARGET_DIR" >&2; exit 2; }

command -v modprobe >/dev/null || { echo "ERROR: modprobe not in PATH" >&2; exit 2; }

mkdir -p "$REPORT_DIR"
USED_SYMS="$REPORT_DIR/used_syms.txt"
USED_CRCS="$REPORT_DIR/used_crcs.txt"
MISSING="$REPORT_DIR/missing_symbols.txt"
CRC_BAD="$REPORT_DIR/crc_mismatch.txt"
KMIDIFF_OUT="$REPORT_DIR/kmidiff.txt"
WHITELIST="$REPORT_DIR/whitelist.kmi"

# 1. Extract <crc, symbol> pairs the module expects.
#    `modprobe --dump-modversions` reads __versions section of the .ko.
modprobe --dump-modversions "$MODULE" > "$USED_CRCS"
awk '{print $2}' "$USED_CRCS" | sort -u > "$USED_SYMS"

n_total=$(wc -l < "$USED_SYMS")

# 2. Compare against target Module.symvers (format: CRC\tsymbol\tmodule\texport).
#    Normalize CRCs to lowercase hex without 0x prefix to dodge formatting drift.
awk '
  function norm(c) { sub(/^0x/, "", c); return tolower(c) }
  NR==FNR { want[$2] = norm($1); next }
  ($2 in want) { have[$2] = norm($1) }
  END {
    for (s in want) {
      if (!(s in have))            print s                                   > "/dev/stderr"
      else if (want[s] != have[s]) printf "%s want=0x%s have=0x%s\n", s, want[s], have[s]
    }
  }
' "$USED_CRCS" "$TARGET_SYMVERS" 2> "$MISSING" > "$CRC_BAD"

n_missing=$(wc -l < "$MISSING")
n_crc=$(wc -l < "$CRC_BAD")

echo "=== Symbol / CRC check ==="
echo "  module:       $MODULE"
echo "  target:       $TARGET_DIR"
echo "  expected:     $n_total symbols"
echo "  missing:      $n_missing  ($MISSING)"
echo "  CRC mismatch: $n_crc  ($CRC_BAD)"

# 3. Optional type-level diff via kmidiff.
TARGET_VMLINUX="$TARGET_DIR/vmlinux"
if [[ -n "$MY_VMLINUX" && -f "$TARGET_VMLINUX" ]]; then
  if ! command -v kmidiff >/dev/null; then
    echo
    echo "kmidiff not installed; skipping type diff."
    echo "  install: sudo apt install abigail-tools"
  else
    {
      echo "[abi_whitelist]"
      sed 's/^/  /' "$USED_SYMS"
    } > "$WHITELIST"

    echo
    echo "=== kmidiff (scoped to module's symbols) ==="
    set +e
    kmidiff \
      --kmi-whitelist "$WHITELIST" \
      --vmlinux1 "$TARGET_VMLINUX" \
      --vmlinux2 "$MY_VMLINUX" \
      "$TARGET_DIR" "$(dirname "$MY_VMLINUX")" \
      > "$KMIDIFF_OUT" 2>&1
    rc=$?
    set -e
    echo "  exit=$rc; report: $KMIDIFF_OUT"
    [[ $rc -ne 0 ]] && echo "  (non-zero exit means kmidiff found differences — read the report)"
  fi
fi

echo
if (( n_missing == 0 && n_crc == 0 )); then
  echo "RESULT: PASS — all $n_total symbols present with matching CRCs."
  exit 0
else
  echo "RESULT: FAIL — module will not load on target kernel."
  exit 1
fi

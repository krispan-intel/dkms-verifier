#!/usr/bin/env bash
# Diff two release reports' summary.csv to show which modules got better,
# worse, appeared, or disappeared between releases.
#
# Usage: diff_releases.sh <tagA> <tagB>
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
A=${1:?tagA}; B=${2:?tagB}
SA="$ROOT/releases/$A/summary.csv"
SB="$ROOT/releases/$B/summary.csv"

[[ -f "$SA" ]] || { echo "missing: $SA" >&2; exit 2; }
[[ -f "$SB" ]] || { echo "missing: $SB" >&2; exit 2; }

OUT="$ROOT/releases/diff-${A}__vs__${B}"
mkdir -p "$OUT"

awk -F, '
  function key(m,t) { return m "@" t }
  NR==FNR && FNR>1 { a[key($1,$2)] = $5; next }
  FNR>1            { b[key($1,$2)] = $5 }
  END {
    print "module,target,A_real_missing,B_real_missing,delta,status"
    for (k in a)        if (!(k in b)) {
      split(k,p,"@"); printf "%s,%s,%d,,,disappeared_in_B\n", p[1], p[2], a[k]
    }
    for (k in b) {
      split(k,p,"@")
      if (!(k in a))    printf "%s,%s,,%d,,appeared_in_B\n", p[1], p[2], b[k]
      else if (a[k] != b[k]) {
        d = b[k] - a[k]
        st = (d > 0 ? "REGRESSED" : "IMPROVED")
        printf "%s,%s,%d,%d,%+d,%s\n", p[1], p[2], a[k], b[k], d, st
      }
    }
  }
' "$SA" "$SB" | tee "$OUT/diff.csv" | column -t -s,
echo
echo "wrote $OUT/diff.csv"

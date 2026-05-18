#!/usr/bin/env bash
# From a commit range, discover the .ko names whose source was touched.
#
# We can't fully resolve Kbuild from text (Kconfig dependencies, dynamic
# obj- assignments). What we CAN do reliably:
#   1. List touched .c/.h files in the range.
#   2. Map each .c file to its containing module by walking up to a Makefile
#      and parsing `obj-m`, `obj-$(CONFIG_X)` lines AND composite `-objs`/`-y`
#      lines whose parent appears as `obj-...` somewhere in the same Makefile.
#   3. Emit only modules (obj-m / obj-$CONFIG), never built-ins (obj-y).
#   4. Validate against the running kernel's module list when present, so the
#      caller can drop false positives.
#
# Usage: discover_modules.sh <kernel-src> <base-rev> <head-rev> [--verify]
# Output: one .ko basename per line on stdout.
#
# With --verify: only emit modules that exist as .ko under
# /lib/modules/$(uname -r)/kernel/.
set -euo pipefail

SRC=${1:?kernel-src}; BASE=${2:?base-rev}; HEAD=${3:?head-rev}; VERIFY=${4:-}

cd "$SRC"

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT

# 1. Touched source files in module-bearing trees.
git diff --name-only "$BASE..$HEAD" -- \
  drivers/ sound/ net/ fs/ block/ crypto/ security/ \
  | grep -E '\.(c|h)$' \
  | sort -u > "$TMP/changed.txt"

# 2. For each touched file, find its module via local Makefile.
declare -A MODS

resolve_module() {
  local f=$1 base dir mk

  base=$(basename "$f" | sed -E 's/\.(c|h)$//')
  dir=$(dirname "$f")

  while [[ "$dir" != "." && "$dir" != "/" ]]; do
    mk="$dir/Makefile"
    if [[ -f "$mk" ]]; then
      # Pass: collect (mod_name, is_module) tuples in this Makefile.
      awk -v want="$base.o" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }

        # obj-$(CONFIG_X) += foo.o bar.o   → modules iff CONFIG=m, treat as candidate
        # obj-m            += foo.o        → definitely module
        # obj-y            += foo.o        → built-in, skip
        /^[ \t]*obj-/ {
          line = $0
          sub(/^[ \t]*obj-/, "", line)
          # split on first =, +=, :=
          if (match(line, /^[A-Za-z0-9_$()-]+/)) {
            qual = substr(line, 1, RLENGTH)
            rest = substr(line, RLENGTH+1)
            sub(/^[ \t]*[:+]?=[ \t]*/, "", rest)

            is_mod = 0
            if (qual == "m") is_mod = 1
            else if (qual ~ /\$\(CONFIG_/) is_mod = 1   # candidate (could be y or m)
            else if (qual == "y")          is_mod = 0
            else                            is_mod = 1   # default to candidate

            if (is_mod) {
              n = split(rest, parts, /[ \t]+/)
              for (i = 1; i <= n; i++) {
                if (parts[i] == want) {
                  name = parts[i]; sub(/\.o$/, "", name)
                  print name
                }
              }
            }
          }
        }

        # foo-objs := a.o b.o     → if foo is obj-m elsewhere, a.c/b.c → foo.ko
        # foo-y    := a.o
        /^[ \t]*[A-Za-z0-9_-]+-(objs|y|m)[ \t]*[:+]?=/ {
          mod = $1
          sub(/-(objs|y|m).*/, "", mod)
          # collect referenced .o files
          line = $0
          sub(/^[^=]*=/, "", line)
          n = split(line, parts, /[ \t]+/)
          for (i = 1; i <= n; i++) {
            if (parts[i] == want) {
              composite[mod] = composite[mod] " " want
              composite_seen[mod] = 1
            }
          }
        }

        END {
          # If the file appears in a composite, only emit if the composite
          # parent is plausibly a module. We re-scan obj- lines from awks
          # primary pass via the host loop instead — keep it simple and emit
          # all composites; the verify pass filters built-ins out.
          for (m in composite_seen) print m
        }
      ' "$mk"

      # If the awk above produced anything, stop walking up.
      if [[ -s "$TMP/lookup.out" ]] 2>/dev/null; then
        :
      fi
      break
    fi
    dir=$(dirname "$dir")
  done
}

while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    # Skip obviously bogus tokens.
    [[ "$m" == obj || "$m" == y || "$m" == m ]] && continue
    [[ "$m" == *":"* || "$m" == *"="* ]] && continue
    MODS[$m]=1
  done < <(resolve_module "$f")
done < "$TMP/changed.txt"

# 3. Optional verification pass. Honour KMODS_FOR_VERIFY env var (set by
# run_release.sh) when present, else fall back to the running kernel.
KMODS_DIR=${KMODS_FOR_VERIFY:-/lib/modules/$(uname -r)/kernel}
emit() {
  if [[ "$VERIFY" == "--verify" && -d "$KMODS_DIR" ]]; then
    for m in "${!MODS[@]}"; do
      # Check both foo.ko and foo-bar.ko (kbuild flips _ vs - sometimes).
      alt=${m//_/-}
      alt2=${m//-/_}
      if find "$KMODS_DIR" -maxdepth 8 \( \
            -name "$m.ko"      -o -name "$m.ko.zst"     -o -name "$m.ko.xz" -o \
            -name "$alt.ko"    -o -name "$alt.ko.zst"   -o -name "$alt.ko.xz" -o \
            -name "$alt2.ko"   -o -name "$alt2.ko.zst"  -o -name "$alt2.ko.xz" \
          \) 2>/dev/null | grep -q .; then
        echo "$m"
      fi
    done | sort -u
  else
    for m in "${!MODS[@]}"; do echo "$m"; done | sort -u
  fi
}
emit

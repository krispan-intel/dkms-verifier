#!/usr/bin/env bash
# Fetch and stage Ubuntu kernel artifacts for check_module.sh.
#
# Produces  <out>/staged/{Module.symvers, vmlinux}  ready to pass as --target.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: fetch_ubuntu_kernel.sh <kernel-version> <out-dir>
  e.g. fetch_ubuntu_kernel.sh 6.8.0-31-generic ./ubuntu-6.8

Downloads via apt:
  linux-headers-<ver>                  (Module.symvers, build/ headers)
  linux-image-unsigned-<ver>-dbgsym    (vmlinux with debug info)

Requires the dbgsym repo. Bootstrap (run once):

  CODENAME=$(lsb_release -cs)
  echo "deb http://ddebs.ubuntu.com $CODENAME main restricted universe multiverse"   | sudo tee /etc/apt/sources.list.d/ddebs.list
  echo "deb http://ddebs.ubuntu.com $CODENAME-updates main restricted universe multiverse" | sudo tee -a /etc/apt/sources.list.d/ddebs.list
  sudo apt install ubuntu-dbgsym-keyring
  sudo apt update

To find versions:
  apt list --all-versions linux-image-generic            # GA
  apt list --all-versions linux-image-generic-hwe-24.04  # HWE
EOF
  exit 2
}

[[ $# -eq 2 ]] || usage
VER=$1
OUT=$2

mkdir -p "$OUT"
cd "$OUT"

echo "Downloading packages for $VER ..."
apt-get download \
  "linux-headers-$VER" \
  "linux-image-unsigned-$VER-dbgsym" \
  || apt-get download \
       "linux-headers-$VER" \
       "linux-image-$VER-dbgsym"

mkdir -p extracted
for d in ./*.deb ./*.ddeb; do
  [[ -f "$d" ]] || continue
  echo "Extracting $d"
  dpkg-deb -x "$d" extracted/
done

mkdir -p staged
SYMVERS=$(find extracted -path '*/usr/src/*' -name Module.symvers | head -1)
VMLINUX=$(find extracted -path '*/usr/lib/debug/*' -name "vmlinux-$VER" | head -1)

[[ -n "$SYMVERS" ]] || { echo "ERROR: Module.symvers not found after extract" >&2; exit 1; }
[[ -n "$VMLINUX" ]] || { echo "WARN: vmlinux with debug info not found — kmidiff will be unavailable" >&2; }

cp "$SYMVERS" staged/Module.symvers
[[ -n "$VMLINUX" ]] && cp "$VMLINUX" staged/vmlinux

echo
echo "Done. Pass to check_module.sh:"
echo "  --target $(realpath "$OUT/staged")"

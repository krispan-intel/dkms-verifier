# Example reports

Two reports produced by `make release-branch` against an Intel OOT kernel
tree, comparing every touched module against Ubuntu 24.04 GA (kernel 6.8)
and Ubuntu 24.04 HWE (kernel 6.17).

| Report | Branch | Tag | Modules |
|---|---|---|---|
| [`lts-v6.18.27-linux-260507T092754Z/`](lts-v6.18.27-linux-260507T092754Z/) | LTS 6.18 | `lts-v6.18.27-linux-260507T092754Z` | 34 |
| [`mainline-preprod-v7.0-linux-260513T080332Z/`](mainline-preprod-v7.0-linux-260513T080332Z/) | mainline-preprod 7.0 | `mainline-preprod-v7.0-linux-260513T080332Z` | 16 |

Open `report.html` in a browser to see the per-module verdicts and the
collapsible per-module list of missing APIs (vs each Ubuntu target).

## What got stripped from these examples

- `imported/` — full extracted module tree (~160 MB), regenerable from the
  upstream artifact.
- `ko/` — decompressed `.ko` files used in the run, regenerable.
- `raw/` — per-module `used_syms.txt` / `missing_symbols.txt` /
  `crc_mismatch.txt`, kept on the live runner; the post-filter
  `analysis/*.txt` is preserved here.
- Absolute paths in `manifest.txt` were replaced with `<KERNEL_SRC>` and
  `<DKMS_VERIFIER>` placeholders.

## Reproducing

From the repo root, against your own OOT kernel tree:

```sh
make refresh-targets
make release-branch \
    BRANCH=<your-branch> \
    SRC=/path/to/kernel-tree \
    ARTIFACT=/path/to/linux-modules.tar.zst
```

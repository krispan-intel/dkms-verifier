# dkms-verifier

Decide whether a kernel module built against **your** OOT (out-of-tree) kernel
will load on a **target** kernel (Ubuntu GA / HWE), and how likely it is to
survive as a DKMS module — repeatable per release tag.

This framework grew out of analysing 335 OOT patches between an upstream
LTS base and an Intel kernel-staging branch, and asking "for each driver
this release touches, will it survive as DKMS on Ubuntu 24.04 GA (kernel
6.8) and HWE (kernel 6.17)?". It generalises to any OOT tree + any set of
target Canonical kernels.

## What it does

- **Discovers** which `.ko` files are affected by an OOT release tag (commits
  between `<base>` and `<head>`).
- **Compares** each module's MODVERSIONS table against every Ubuntu KMI
  baseline listed in `targets.conf`.
- **Classifies** each (module, target) pair as DKMS OK / with-shims / high
  risk / very-high-risk based on real-missing API count.
- **Emits** a self-contained HTML report in `releases/<tag>/report.html`.
- **Diffs** consecutive releases to surface improvements/regressions.

## Quick start

```sh
# 1. Bootstrap Ubuntu dbgsym repo (one-time):
CODENAME=$(lsb_release -cs)
echo "deb http://ddebs.ubuntu.com $CODENAME main restricted universe multiverse" \
  | sudo tee /etc/apt/sources.list.d/ddebs.list
echo "deb http://ddebs.ubuntu.com $CODENAME-updates main restricted universe multiverse" \
  | sudo tee -a /etc/apt/sources.list.d/ddebs.list
sudo apt install ubuntu-dbgsym-keyring abigail-tools binutils kmod dpkg-dev zstd xz-utils
sudo apt update

# 2. Cache the Ubuntu baselines listed in targets.conf:
make refresh-targets

# 3. Run a release report. The simplest entry point — give it a branch:
make release-branch \
    BRANCH=origin/6.18/linux \
    SRC=/path/to/kernel-tree

# 4. Open the report:
xdg-open releases/lts-v6.18.27-linux-260507T092754Z/report.html
```

Two example reports — one for an LTS 6.18 branch, one for a
mainline-preprod 7.0 branch — are checked in under
[`examples/`](examples/). They show what `report.html`, `summary.csv`,
`modules.txt`, and `analysis/` look like.

The branch must have a release tag at its tip (`lts-v*-linux-*` or
`mainline-preprod-v*-linux-*`); `scripts/resolve_branch.sh` derives
`TAG / BASE / HEAD` automatically.

If you have a prebuilt module artifact (a deb, a tarball, or a directory):

```sh
make release-branch \
    BRANCH=origin/6.18/linux \
    SRC=/path/to/kernel-tree \
    ARTIFACT=/path/to/linux-modules.tar.zst
```

Without `ARTIFACT`, the framework reads `.ko` files from
`/lib/modules/$(uname -r)/kernel` (i.e. the running kernel — only useful when
the running kernel *is* the OOT build).

## Tag conventions

`scripts/parse_tag.sh` extracts the OOT baseline (`BASE`) from the tag:

| Tag                                              | BASE      | STREAM             |
|---|---|---|
| `lts-v6.18.27-linux-260507T092754Z`              | `v6.18.27`| `lts`              |
| `mainline-preprod-v7.0-linux-260513T080332Z`     | `v7.0`    | `mainline-preprod` |

When the tag is not currently checked out (e.g. it points at
`origin/6.18/linux` while the working tree is on a different branch), pass
`HEAD=<rev>` explicitly. CI always should.

## Adding a new Canonical release as a target

Edit `targets.conf`:

```
ubuntu-24.04-ga       6.8.0-31-generic       Ubuntu 24.04 GA (kernel 6.8)
ubuntu-24.04-hwe      6.17.0-23-generic      Ubuntu 24.04 HWE (kernel 6.17)
ubuntu-25.04          6.14.0-19-generic      Ubuntu 25.04 (plucky)
```

Then:
```sh
make refresh-targets
make release TAG=... SRC=... HEAD=...
```
The HTML report grows columns automatically — no script changes needed.

## What the three "layers" of ABI mean

| Layer | Enforced by | Scope |
|---|---|---|
| **Symbol presence** | `insmod` | Does the target export every symbol the module imports? |
| **CRC match** | `insmod` (MODVERSIONS) | Same CRC means binary-compatible — DKMS rebuild always picks up the new CRC, so CRC mismatches are noise for DKMS analysis. |
| **Type-level ABI** | The compiler when DKMS rebuilds | Function signatures, struct layouts. Catches what would make DKMS *fail to compile*. |

This framework focuses on layers 1 + 2, with layer 1 ("real-missing") being
the actual DKMS blocker. Layer 3 (`kmidiff`, `stgdiff`) is supported by
`check_module.sh` when invoked directly with `--my-vmlinux`, but is not yet
part of the per-release pipeline.

### "Real-missing" filter

The HTML strips a small allow-list of kernel-internal renames that don't
break DKMS rebuilds:

```
*_noprof                   # mem profiling rename (6.10+)
__ref_stack_chk_guard      # stack protector
__fortify_panic            # FORTIFY_SOURCE
__preempt_count            # preempt counter
const_current_task         # current_task constification
```

Adjust in `scripts/run_release.sh` if your kernel adds more such renames.

## Per-release output layout

```
releases/<tag>/
├── manifest.txt                  # tag, base, head, generation timestamp
├── modules.txt                   # modules discovered from the diff
├── summary.csv                   # the master numbers
├── report.html                   # the human-readable report
├── ko/                           # decompressed .ko files used in this run
├── analysis/
│   └── <module>-vs-<target>-real-missing.txt   # filtered API list
└── raw/
    └── <module>-vs-<target>/
        ├── used_syms.txt
        ├── missing_symbols.txt
        ├── crc_mismatch.txt
        └── used_crcs.txt
```

## Comparing two releases

```sh
make compare A=lts-v6.18.27-linux-260507T092754Z \
             B=lts-v6.18.27-linux-260513T080332Z
```

Output: a table of (module, target, A_real_missing, B_real_missing, delta,
status) — one row per pair where the count changed.

## Jenkins integration

`dkms-verifier` is intended to run as **one job among many** in a kernel CI
pipeline. It does not build the kernel; an upstream Jenkins job is expected
to build the OOT kernel and archive the modules as an artifact.

Pipeline stages in `Jenkinsfile`:

1. Checkout the dkms-verifier repo.
2. Resolve `$BRANCH` → `TAG / BASE / HEAD`. Fail fast if no release tag
   points at the branch tip.
3. (Optional) Refresh Ubuntu baselines.
4. `copyArtifacts` from `$UPSTREAM_JOB` to pull the modules tarball/deb.
5. `make release-branch` with `ARTIFACT=<the copied artifact>`.
6. Diff against the previous release.
7. Archive `releases/<tag>/` and publish the HTML report.

Required Jenkins parameters:

| Parameter | Example | Purpose |
|---|---|---|
| `BRANCH` | `origin/6.18/linux` | Which branch to evaluate |
| `KERNEL_SRC` | `/srv/ci/kernel-lts-staging` | OOT kernel git tree on the agent |
| `UPSTREAM_JOB` | `kernel-build-oot` | The build job that produced modules |
| `UPSTREAM_BUILD_SELECTOR` | `lastSuccessful` | Which upstream build to copy from |
| `UPSTREAM_ARTIFACT_GLOB` | `linux-modules-*.tar.*` | What to grab |

**Upstream artifact contract.** The upstream build job must archive a
single artifact that `import_modules.sh` recognises:

- a directory with a `lib/modules/<ver>/kernel/` subtree, or
- a `linux-image-*.deb` / `linux-modules-*.deb`, or
- a `.tar` / `.tar.gz` / `.tar.xz` / `.tar.zst` of either of the above.

Recommended shape: `linux-modules-<branch>.tar.zst` containing
`lib/modules/<ver>/kernel/...`.

**Required Jenkins plugins**: Pipeline, Git, Copy Artifact, HTML Publisher.
Optional: Slack / Email Extension for failure notification (templates in the
`post { failure { ... } }` block, commented out).

## Files

| File | Purpose |
|---|---|
| `Makefile` | Top-level entry: `release`, `release-branch`, `refresh-targets`, `compare` |
| `Jenkinsfile` | CI pipeline |
| `targets.conf` | Ubuntu KMI baselines (extend here) |
| `scripts/parse_tag.sh` | Tag → BASE/STREAM/STAMP |
| `scripts/resolve_branch.sh` | Branch → (TAG, BASE, HEAD) |
| `scripts/discover_modules.sh` | Diff → list of `.ko` names |
| `scripts/refresh_targets.sh` | Apt-fetch and stage all targets |
| `scripts/import_modules.sh` | Stage upstream-job artifact as a kmods tree |
| `scripts/run_release.sh` | Tag → full report (orchestrator) |
| `scripts/build_report.sh` | summary.csv → report.html |
| `scripts/diff_releases.sh` | A/B summary delta |
| `check_module.sh` | Single-module CRC check + optional kmidiff |
| `fetch_ubuntu_kernel.sh` | Stage one Ubuntu kernel as a target |

## Caveats

- `discover_modules.sh` is heuristic — Kbuild can hide modules behind
  Kconfig or dynamic obj- assignment. Use `--verify` (default in
  `run_release.sh`) to drop names that don't exist as `.ko` in the running
  tree.
- The CRC layer requires `CONFIG_MODVERSIONS=y` in your OOT kernel build.
- Module signing / Secure Boot lockdown is a separate concern — a clean ABI
  pass does not imply the module will load on a locked-down system.
- `kmidiff` (type-level diff) is wired into `check_module.sh` but not yet
  part of `run_release.sh`. Add it when you want to catch struct-layout
  changes that don't show up in CRC alone.

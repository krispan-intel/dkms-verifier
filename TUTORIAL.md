# Step-by-step tutorial for beginners

> Languages: **English** · [简体中文](TUTORIAL.zh-CN.md) · [繁體中文](TUTORIAL.zh-TW.md)

For first-time users of `dkms-verifier` who want to follow along without
needing prior kernel/ABI background. Every command is copy-paste ready.

If you don't know what "KMI", "DKMS", or "Module.symvers" mean, ignore that
for now and just follow the steps. There's a glossary at the end.

---

## What you will produce

Given an OOT kernel branch name, you'll run one command and produce an HTML
report that answers:
**"For each driver this release touches, can it become a DKMS module on
Ubuntu 24.04?"**

---

## What you need

- A machine (or VM) running Ubuntu 24.04
- sudo
- ~30 minutes the first time
- ~1-2 minutes per run after that

---

## Step 1 — Install tools

```sh
sudo apt update
sudo apt install -y git make abigail-tools binutils kmod dpkg-dev zstd xz-utils lsb-release
```

Verify:

```sh
which kmidiff modprobe dpkg-deb make zstd
```

Each line should print a path. If `kmidiff` is missing, `abigail-tools`
didn't install correctly.

---

## Step 2 — Clone the repo

```sh
cd ~
git clone https://github.com/krispan-intel/dkms-verifier.git
cd dkms-verifier
```

---

## Step 3 — Bootstrap the Ubuntu dbgsym repo (one-time)

We need to fetch `Module.symvers` from the Ubuntu archive. Add the dbgsym
sources first:

```sh
CODENAME=$(lsb_release -cs)
echo "deb http://ddebs.ubuntu.com $CODENAME main restricted universe multiverse" \
  | sudo tee /etc/apt/sources.list.d/ddebs.list
echo "deb http://ddebs.ubuntu.com $CODENAME-updates main restricted universe multiverse" \
  | sudo tee -a /etc/apt/sources.list.d/ddebs.list
sudo apt install -y ubuntu-dbgsym-keyring
sudo apt update
```

If `apt update` complains about GPG, re-run `sudo apt install -y
ubuntu-dbgsym-keyring`.

---

## Step 4 — Cache Ubuntu kernel baselines

```sh
make refresh-targets
```

This downloads each Ubuntu kernel package listed in `targets.conf`. First
run is ~2-3 minutes / ~150 MB. You should see:

```
Cached targets:
  ubuntu-24.04-ga        symvers=30190 lines +vmlinux
  ubuntu-24.04-hwe       symvers=32890 lines +vmlinux
```

Subsequent `make refresh-targets` runs skip cached targets — seconds.

---

## Step 5 — Get the OOT kernel tree

Your mentor will give you an internal git URL (the long kind). Clone it
**outside** the dkms-verifier directory:

```sh
cd ~
git clone <URL-from-your-mentor> kernel-tree
```

> ⚠️ Don't clone it into `dkms-verifier/`. `~/kernel-tree` is fine.

---

## Step 6 — Find the branch name

Your mentor will give you a branch name. Common shapes:

- `origin/6.18/linux` (LTS)
- `mlt-staging/mainline-tracking/v7.0` (mainline-preprod)

Confirm the branch tip has a release tag:

```sh
cd ~/kernel-tree
git tag --points-at <branch-name> | grep -E '^(lts-v|mainline-preprod-v)'
```

Example:

```sh
git tag --points-at origin/6.18/linux | grep -E '^(lts-v|mainline-preprod-v)'
```

If something prints (e.g. `lts-v6.18.27-linux-260507T092754Z`) ✅ continue.

If nothing prints ❌, tell your mentor: "the branch tip has no qualifying
release tag."

---

## Step 7 — Get the module artifact (important)

`dkms-verifier` does not build the kernel itself. You need to download
modules built by an **upstream Jenkins build job**. Ask your mentor:

> "Which Jenkins job produces the OOT kernel modules artifact?"

The artifact is usually a file from a Jenkins job's archive area, with one
of these formats:
- `linux-modules-*.tar.zst` (most common)
- `linux-modules-*.deb`
- `linux-image-*.deb`
- a directory (if shipped via NFS / shared storage)

Download to your machine:

```sh
mkdir -p ~/Downloads/oot
cd ~/Downloads/oot
# wget / scp / Jenkins web UI — any of them works
```

---

## Step 8 — Run the report

```sh
cd ~/dkms-verifier
make release-branch \
  BRANCH=origin/6.18/linux \
  SRC=~/kernel-tree \
  ARTIFACT=~/Downloads/oot/linux-modules-XXX.tar.zst
```

Replace `BRANCH=...` and `ARTIFACT=...` with your values.

Successful output looks like:

```
[release-branch] BRANCH=origin/6.18/linux TAG=lts-v6.18.27-linux-... BASE=v6.18.27 HEAD=...
[13:48:23] discovering modules (v6.18.27..722b023c...)
[13:48:31]   34 modules to check
...
[13:48:33] done → /home/.../releases/lts-v6.18.27-linux-260507T092754Z
```

---

## Step 9 — Open the report

```sh
xdg-open releases/<the-TAG>/report.html
```

Example:

```sh
xdg-open releases/lts-v6.18.27-linux-260507T092754Z/report.html
```

That HTML is the deliverable.

---

## Step 10 — Reading the report

### Top section — TL;DR

Two cards, one per Ubuntu target:

```
Ubuntu 24.04 GA (kernel 6.8)         Ubuntu 24.04 HWE (kernel 6.17)
12 DKMS OK   8 with shims  4 high    32 DKMS OK  2 with shims  0 high
```

### Middle — Per-module verdicts table

One row per module. `real-missing` is the count of APIs that will actually
block a DKMS rebuild. The verdict column says it all:

| Color | Meaning |
|---|---|
| 🟢 **DKMS OK** | Just rebuild — 0 missing APIs |
| 🟡 **DKMS with shims** | 1-5 missing APIs, write compat wrappers |
| 🔴 **High risk** | 6-30 missing, large backport needed |
| 🔴 **Very high risk** | 30+ missing, ship a custom kernel instead |

Click a module name to jump to its missing-API detail below.

### Bottom — Per-module detail

A collapsible block per module listing the missing APIs vs each Ubuntu
target. This is what you'll quote back to your mentor.

---

## How to report your findings

Open a ticket / send mail with:

```
Branch:                     origin/6.18/linux
Tag:                        lts-v6.18.27-linux-260507T092754Z
Modules touched:            34
DKMS OK @ 24.04 GA:         12
DKMS with shims @ 24.04 GA:  8
High risk @ 24.04 GA:        4   ← list these out
Very high risk @ 24.04 GA:   0

Report: <upload report.html to a share drive or attach to the ticket>
```

---

## Troubleshooting

### `make refresh-targets` fails to download

```
E: Unable to locate package linux-image-unsigned-X.Y.Z-XX-generic-dbgsym
```

→ Step 3 (the dbgsym repo) wasn't set up. Redo Step 3, especially `sudo
apt update`.

### `ERROR: no release tag found at <branch>`

→ The branch tip has no release tag. Re-check Step 6 — verify the branch
name with your mentor.

### `ERROR: kmods dir not found`

→ Missing `ARTIFACT=`, or wrong path. Go back to Steps 7-8.

### `ERROR: BASE rev 'vX.Y.Z' not found in <SRC>`

→ The kernel tree didn't fetch upstream tags. Run:
```sh
cd ~/kernel-tree
git fetch --tags
```

### Output says "0 modules"

→ Branch tip equals base, or the branch name is misspelled. Check:
```sh
cd ~/kernel-tree
git log --oneline v6.18.27..origin/6.18/linux | head
```
There must be commits.

---

## Smoke-test the tool without OOT access (demo)

Don't have OOT kernel access yet? Test the toolchain with the running
kernel:

```sh
cd ~/dkms-verifier

# 1. Pick any .ko already on the system
cp /lib/modules/$(uname -r)/kernel/drivers/edac/igen6_edac.ko.zst /tmp/
zstd -d /tmp/igen6_edac.ko.zst -o /tmp/igen6_edac.ko

# 2. Run an ABI check against Ubuntu 24.04 GA (kernel 6.8)
./check_module.sh \
  --module /tmp/igen6_edac.ko \
  --target targets/ubuntu-24.04-ga/staged \
  --report /tmp/demo
```

Expected output:

```
=== Symbol / CRC check ===
  expected:     49 symbols
  missing:      2
  CRC mismatch: 47

RESULT: FAIL — module will not load on target kernel.
```

That confirms the toolchain works; you're now waiting on an OOT branch +
artifact.

---

## Glossary

| Term | Meaning |
|---|---|
| **OOT** | Out-of-tree. Kernel patches maintained internally that haven't been upstreamed. |
| **DKMS** | Dynamic Kernel Module Support. Lets a module be rebuilt against a different kernel without rebuilding everything. |
| **KMI** | Kernel Module Interface. The ABI boundary between the kernel and modules. |
| **Module.symvers** | A file listing the CRC (version fingerprint) of every kernel-exported symbol. `insmod` checks against this when loading a module. |
| **CRC mismatch** | The symbol exists but its version differs. Fixed by recompiling — exactly the DKMS use case. |
| **Real-missing** | The symbol is gone entirely. Recompiling won't help; you must backport the API or patch the source. |

---

## Want to learn more?

- `README.md` — full framework documentation
- `BACKGROUND.md` — methodology lineage (Greg KH stable kernel + Android GKI)
- `examples/` — two real release reports
- `Jenkinsfile` — full CI pipeline
- `make help` — list of all available targets

Questions? Ask your mentor or open an issue:
https://github.com/krispan-intel/dkms-verifier/issues

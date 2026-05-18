# Where this came from — Android GKI & Greg KH

> Languages: **English** · [简体中文](BACKGROUND.zh-CN.md) · [繁體中文](BACKGROUND.zh-TW.md)

`dkms-verifier` did not appear out of thin air. It splices together two
existing schools of kernel ABI governance and adapts them for one specific
use case: "OOT kernel → Ubuntu DKMS". After reading this you will know:

- which concepts came from Greg KH (upstream stable maintainer)
- which came from Android GKI
- what we changed and why

You don't need to understand Android to use the framework — this doc is for
people curious **why** it looks the way it does.

---

## The two existing schools

### School 1: Greg KH / upstream stable kernel

**Goal**: keep Linux LTS series (v6.6, v6.12, v6.18, …) in a state that
"doesn't break existing modules."

**How**:
- **`CONFIG_MODVERSIONS=y`** — the kernel computes a CRC for every exported
  symbol and stores it in `Module.symvers`.
- **`scripts/genksyms`** computes those CRCs.
- On load, `insmod` compares the module's `__versions` section against the
  kernel's CRCs; mismatch = refuse.
- **No automated ABI tooling** — relies on **patch-review discipline**:
  `stable-kernel-rules.rst` explicitly forbids changing `EXPORT_SYMBOL`
  signatures, struct reordering, removing exports, etc.
- Anyone who wants a diff runs [libabigail](https://sourceware.org/libabigail/)'s
  `abidiff` / `kmidiff` themselves.

**Greg doesn't run STG; he relies on process + MODVERSIONS CRC.**
That is the original source of `dkms-verifier`'s **CRC layer** —
`check_module.sh` is essentially a modversion comparison.

References:
- `Documentation/process/stable-kernel-rules.rst`
- https://www.kernel.org/category/releases.html

### School 2: Android Common Kernel (ACK) + GKI

**Goal**: let partner vendors (Qualcomm, MediaTek, Samsung, Pixel, …) ship
modules that don't need re-porting on every LTS bump, as long as they stick
to the published GKI KMI.

This is **automated, tag-driven, whitelist-scoped** ABI governance.

If you clone an Android Common Kernel:

```
android-mainline/
├── android/
│   └── abi_gki_aarch64.xml     # earlier libabigail-XML form
└── gki/
    └── aarch64/
        ├── abi.stg                  # 7-8 MB STG snapshot of the approved KMI
        ├── abi.stg.allowed_breaks   # accepted exceptions
        └── symbols/
            ├── base                 # GKI core
            ├── qcom                 # Qualcomm
            ├── mtk                  # MediaTek
            ├── pixel                # Google
            └── ...                  # one per partner
```

Key concepts:

| Concept | Android way | dkms-verifier way |
|---|---|---|
| **Per-release ABI snapshot** | Every tag push triggers CI to rebuild the kernel, extract a fresh `abi.stg`, diff against the previous one, reject violators. | Every release tag → `make release-branch` → `releases/<tag>/report.html`. |
| **Symbol whitelist scope** | Partners register the symbols they use in `symbols/<partner>`; ABI is enforced only on those. | Automatic: `modprobe --dump-modversions` extracts the symbols a module actually uses, and that becomes its whitelist. |
| **Allowed breaks** | `abi.stg.allowed_breaks` lists pre-approved breakages; CI lets them through. | We don't have this — DKMS context only asks "will this load?", every break must be reported. |
| **Tooling** | Google [STG](https://github.com/google/stg) (`stg`, `stgdiff`) over BTF/DWARF — much faster than libabigail. | libabigail's `kmidiff` — `apt install abigail-tools` is enough; works across distros. |
| **CI surface** | Bazel + Kleaf: `tools/bazel run //common:kernel_aarch64_abi_dist`. | Jenkins + Make: `make release-branch BRANCH=...`. |

References:
- Android GKI overview — https://source.android.com/docs/core/architecture/kernel/generic-kernel-image
- KMI symbol-list spec — https://source.android.com/docs/core/architecture/kernel/symbols
- STG repo — https://github.com/google/stg
- Kleaf docs — `build/kernel/kleaf/README.md` inside an ACK tree

---

## Combining the two → dkms-verifier

`dkms-verifier` borrows the **automation framework** from Android GKI and the
**MODVERSIONS CRC enforcement** from Greg KH, and combines them for a third
use case:

> "I have an OOT kernel; I want my modules to run on Ubuntu LTS — can they
>  be a DKMS package?"

### What we borrowed from Android

1. **"Track ABI per release tag"** — the `releases/<tag>/` directory layout.
   GKI: one tag = one `abi.stg`; us: one tag = one `summary.csv` +
   `report.html`.

2. **Symbol whitelist scope** — Android's `symbols/<partner>` →
   our "the set of symbols a module actually imports, extracted live with
   `nm -u`". Both solve the same problem: **whole-kernel diffs are too
   noisy; scope first**.

3. **The two-tier classification (CRC vs Real-missing)** — same shape as
   Android's "symbol still there but type changed" vs "symbol gone."

4. **The spirit of `allowed_breaks`** — `run_release.sh` hardcodes a small
   set of kernel-internal renames (`*_noprof`, `__ref_stack_chk_guard`,
   `__fortify_panic`, …) that don't count as real-missing. A miniature
   `abi.stg.allowed_breaks`.

5. **Tag-driven CI** — `Jenkinsfile` ↔ `copyArtifacts` ↔ `publishHTML`
   maps 1:1 to Android's "tag push → ABI job runs → report published."

### What we borrowed from Greg KH

1. **MODVERSIONS CRC is the actual `insmod` gatekeeper** — that's our
   "CRC mismatch" layer.
2. **`Module.symvers` is the file contract** — `refresh_targets.sh`
   downloads exactly that file.
3. **"Don't over-engineer"** — Greg gets along fine without STG, so we
   chose not to ship STG either; `kmidiff` (one apt command) covers most
   needs.

### What we changed

| Change | Reason |
|---|---|
| `stg` / `stgdiff` → `kmidiff` (libabigail) | One apt line, no build. STG isn't pleasant outside Android's toolchain. |
| Static partner symbol list → dynamic per-`.ko` extraction | OOT use case has no notion of partners, but every run has concrete modules. |
| No `abi.stg.allowed_breaks` workflow | DKMS-perspective: every break matters, none is "approvable away." |
| Added the "real-missing" filter | Greg and Android don't need it because they recompile the kernel; we recompile only the module (DKMS), so we must distinguish "rebuild can fix this" vs "it can't." |
| Diff against multiple Ubuntu targets at once | Android: one release ↔ one KMI. Us: a single release may need to target both 6.8 GA and 6.17 HWE; `targets.conf` is a list. |

---

## One-line summary

> **Greg KH's stable-kernel discipline** told us "modversion CRC is the
> thing actually being guarded."
> **Android GKI** told us "ABI governance can be automated, tag-driven,
> and whitelist-scoped."
> **`dkms-verifier`** = (Greg's CRC) × (Android's automation) × (DKMS's
> real-missing filter).

---

## Looking at the real thing

If you want to see how Android actually does it:

```sh
# Grab an Android Common Kernel
git clone https://android.googlesource.com/kernel/common -b android-mainline
cd common

# ABI snapshot
ls -la gki/aarch64/abi.stg
head -50 gki/aarch64/abi.stg

# Partner symbol lists
ls gki/aarch64/symbols/
head -20 gki/aarch64/symbols/base
wc -l gki/aarch64/symbols/qcom

# Allowed breaks
head gki/aarch64/abi.stg.allowed_breaks

# Bazel / Kleaf entry point
cat build/kernel/kleaf/README.md | head -40
```

Side-by-side mappings:

- Our `targets/<id>/staged/Module.symvers` ≈ Android's
  `gki/aarch64/abi.stg` (simplified).
- Our `releases/<tag>/analysis/<mod>-vs-<target>-real-missing.txt` ≈
  Android's ABI diff report.
- Our `targets.conf` ≈ Android's `symbols/` directory concept (inverted —
  scope is set by the *target* rather than by the module).
- Our `make release-branch` ≈ Android's
  `tools/bazel run //common:kernel_aarch64_abi_dist`.

---

## Further reading

- **GKI overview** — https://source.android.com/docs/core/architecture/kernel/generic-kernel-image
- **KMI versioning** — https://source.android.com/docs/core/architecture/kernel/kmi-versioning
- **STG paper / talk** — https://lpc.events/event/16/contributions/1180/
- **libabigail kmidiff** — `man kmidiff` or
  https://sourceware.org/libabigail/manual/kmidiff.html
- **Greg KH stable rules** — `Documentation/process/stable-kernel-rules.rst` in any kernel tree
- **modversions explained** — `Documentation/kbuild/modules.rst` in any kernel tree

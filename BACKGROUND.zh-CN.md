# 方法论的血统 — Android GKI & Greg KH

> Languages: [English](BACKGROUND.md) · **简体中文** · [繁體中文](BACKGROUND.zh-TW.md)

`dkms-verifier` 不是凭空想出来的。它把两种既存的 kernel ABI 治理思路接起来，
然后改造成适合「OOT kernel → Ubuntu DKMS」这个 use case。读完这份你就知道：

- 哪些概念是抄 Greg KH (upstream stable maintainer) 的
- 哪些是抄 Android GKI 的
- 我们改了什么、为什么改

不需要事先了解 Android 也能用 framework；这份只是给想知道**为什么长这样**的人看。

---

## 两种既有的 ABI 治理流派

### 流派 1: Greg KH / upstream stable kernel

**目标**：把 Linux LTS（v6.6、v6.12、v6.18 …）维持在「不破坏既有 module」的状态。

**做法**：
- **`CONFIG_MODVERSIONS=y`** — kernel 为每个 export symbol 算一个 CRC，存在 `Module.symvers`。
- **`scripts/genksyms`** 算 CRC。
- 加载 module 时，`insmod` 比对 module `__versions` section 和 kernel CRC，不一致就拒载。
- **没有**自动化 ABI tooling，靠**patch review 规范**：`stable-kernel-rules.rst` 明文禁止改变 `EXPORT_SYMBOL` 签名、struct 重排、删除 export 等。
- 想 diff 的人自己跑 [libabigail](https://sourceware.org/libabigail/) 的 `abidiff` / `kmidiff`。

**Greg 不跑 STG，他靠流程 + MODVERSIONS CRC**。
这就是 `dkms-verifier`「**CRC layer**」的原始来源 — `check_module.sh` 跑的就是 modversion 比对。

参考：
- `Documentation/process/stable-kernel-rules.rst`
- https://www.kernel.org/category/releases.html

### 流派 2: Android Common Kernel (ACK) + GKI

**目标**：让 partner（高通、联发科、三星、Pixel...）写的 vendor module，
不需要每个 LTS 升级都重新 port，只要遵守 GKI 公布的 KMI 就保证能加载。

这是**自动化、tag-driven、whitelist-scoped** 的 ABI 治理。

如果你 clone 一份 Android Common Kernel 看：

```
android-mainline/
├── android/
│   └── abi_gki_aarch64.xml     # 早期版本，libabigail XML
└── gki/
    └── aarch64/
        ├── abi.stg                  # 7-8 MB STG snapshot of approved KMI
        ├── abi.stg.allowed_breaks   # accepted exceptions list
        └── symbols/
            ├── base                 # GKI core symbol list
            ├── qcom                 # Qualcomm's symbols
            ├── mtk                  # MediaTek
            ├── pixel                # Google's
            └── ...                  # one per partner
```

关键概念：

| 概念 | Android 怎么做 | dkms-verifier 怎么用 |
|---|---|---|
| **Per-release ABI snapshot** | 每次 push tag 时，CI 重 build kernel + 抽出新的 `abi.stg`，对旧版 diff，违反就 reject。 | 每个 release tag 跑一次 `make release-branch`，产 `releases/<tag>/report.html`。 |
| **Symbol whitelist scope** | partner 注册「我会用到的 symbol」到 `symbols/<partner>`，ABI 只在这些 symbol 上强制。 | 自动：`modprobe --dump-modversions` 抽 module 真正用到的 symbol 当 whitelist。 |
| **Allowed breaks** | `abi.stg.allowed_breaks` 列出已批准的破坏，CI 看到列表内的 diff 就放行。 | 我们不做 — DKMS context 只问「能不能加载」，每个 break 都要报。 |
| **Tooling** | Google [STG](https://github.com/google/stg) (`stg`, `stgdiff`)，from BTF/DWARF，比 libabigail 快很多。 | 用 libabigail 的 `kmidiff` — `apt install abigail-tools` 一行搞定，跨 distro 通用。 |
| **CI 接点** | Bazel + Kleaf：`tools/bazel run //common:kernel_aarch64_abi_dist`。 | Jenkins + Makefile：`make release-branch BRANCH=...`。 |

参考：
- Android GKI 总览：https://source.android.com/docs/core/architecture/kernel/generic-kernel-image
- KMI symbol list 规范：https://source.android.com/docs/core/architecture/kernel/symbols
- STG repo：https://github.com/google/stg
- Kleaf (Bazel 包装层) 文档：在 Android Common Kernel 树里 `build/kernel/kleaf/README.md`

---

## 两流派合起来 → dkms-verifier

`dkms-verifier` 借 Android GKI 的**自动化框架**和 Greg KH 的**MODVERSIONS CRC 主力**，组合成第三个 use case：

> 「我有 OOT kernel，想在 Ubuntu LTS 上跑 — 我的 module 能不能变成 DKMS package？」

### 从 Android 借来的东西

1. **「Track ABI per release tag」** — `releases/<tag>/` 目录结构就是这个概念。
   GKI 一个 tag = 一份 `abi.stg`；我们一个 tag = 一份 `summary.csv` + `report.html`。

2. **Symbol whitelist scope** — Android 的 `symbols/<partner>` → 我们的「module 自己用 `nm -u` 抽出来的 symbol set」。
   两者都解决同一个问题：**全 kernel diff 噪音太多，要先框小范围**。

3. **CRC vs Real-missing 的二层分层** — 跟 Android「symbol 还在但 type 变了」vs「symbol 完全不见」的分类同源。

4. **`allowed_breaks` 的精神** — 我们在 `run_release.sh` 里 hardcode 一组 kernel-internal renames
   （`*_noprof`、`__ref_stack_chk_guard`、`__fortify_panic`...）当「允许清单」，
   不算进 real-missing。等于精简版的 `abi.stg.allowed_breaks`。

5. **Tag-driven CI** — `Jenkinsfile` 接 `copyArtifacts` + `publishHTML`，
   跟 Android 的「每个 tag push → ABI job 跑 → 报告 publish」流程一比一。

### 从 Greg KH 借来的东西

1. **MODVERSIONS CRC 是真正能挡 `insmod` 的东西** — 我们的「CRC mismatch」就是这层。
2. **`Module.symvers` 是文件契约** — refresh_targets.sh 抓的就是这个文件。
3. **「不要过度 engineer」的精神** — Greg 不跑 STG 也活得好，所以我们也决定先不跑 STG，
   用 `kmidiff`（一个 apt 命令）就能 cover 大部分需求。

### 我们改了什么

| 改动 | 原因 |
|---|---|
| `stg` / `stgdiff` → `kmidiff` (libabigail) | apt 一行装完，不用 build。STG 在 Android 工具链外不好用。 |
| 静态 partner symbol list → 动态从 `.ko` 抽 | OOT use case 不知道哪家 partner，但每次都有具体 module。 |
| 不做 `abi.stg.allowed_breaks` | DKMS 角度每个 break 都重要，不能「批准」掉。 |
| 加「real-missing 过滤」 | Greg 跟 Android 都不需要这个，因为他们重编 kernel；我们是 DKMS（重编 module 但不重编 kernel），所以要区分「rebuild 救得到」vs「救不到」。 |
| 加「对多个 Ubuntu target 同时 diff」 | Android 一个 release 对应一个 KMI；我们可能要同时对 6.8 GA + 6.17 HWE，所以 `targets.conf` 是 list。 |

---

## 一句话总结

> **Greg KH 的 stable kernel 流程**告诉我们「modversion CRC 是真正在守的东西」。
> **Android GKI** 告诉我们「ABI 治理可以自动化、可以 tag-driven、可以用 symbol whitelist 框 scope」。
> **`dkms-verifier`** = (Greg 的 CRC) × (Android 的自动化) × (DKMS 的 real-missing 过滤)。

---

## 想看真品

如果你想看 Android 是怎么做的：

```sh
# 找一棵 Android Common Kernel
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

# Bazel 入口（Kleaf）
cat build/kernel/kleaf/README.md | head -40
```

跟 `dkms-verifier` 对着看，会发现：

- 我们的 `targets/<id>/staged/Module.symvers` ≈ Android 的 `gki/aarch64/abi.stg`（简化版）
- 我们的 `releases/<tag>/analysis/<mod>-vs-<target>-real-missing.txt` ≈ Android 的 ABI diff report
- 我们的 `targets.conf` ≈ Android 的 `symbols/` 目录概念（但反过来，由 target 决定范围而不是 module）
- 我们的 `Makefile release-branch` target ≈ Android 的 `tools/bazel run //common:kernel_aarch64_abi_dist`

---

## 延伸阅读

- **GKI overview** — https://source.android.com/docs/core/architecture/kernel/generic-kernel-image
- **KMI versioning** — https://source.android.com/docs/core/architecture/kernel/kmi-versioning
- **STG paper / talk** — https://lpc.events/event/16/contributions/1180/
- **libabigail kmidiff** — `man kmidiff` 或 https://sourceware.org/libabigail/manual/kmidiff.html
- **Greg KH stable rules** — `Documentation/process/stable-kernel-rules.rst` in any kernel tree
- **modversions explained** — `Documentation/kbuild/modules.rst` in kernel tree

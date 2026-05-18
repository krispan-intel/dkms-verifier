# Where this came from — Android GKI &amp; Greg KH

`dkms-verifier` 不是憑空想出來的。它把兩種既存的 kernel ABI 治理思路接起來，
然後改造成適合「OOT kernel → Ubuntu DKMS」這個 use case。讀完這份你就知道：

- 哪些概念是抄 Greg KH (upstream stable maintainer) 的
- 哪些是抄 Android GKI 的
- 我們改了什麼、為什麼改

不需要事先了解 Android 也能用 framework；這份只是給想知道**為什麼長這樣**的人看。

---

## 兩種既有的 ABI 治理流派

### 流派 1: Greg KH / upstream stable kernel

**目標**：把 Linux LTS（v6.6, v6.12, v6.18 …）維持在「不破壞既有 module」的狀態。

**做法**：
- **`CONFIG_MODVERSIONS=y`** — kernel 為每個 export symbol 算一個 CRC，存在 `Module.symvers`。
- **`scripts/genksyms`** 算 CRC。
- 載入 module 時，`insmod` 比對 module `__versions` section 和 kernel CRC，不一致就拒載。
- **沒有**自動化 ABI tooling，靠**patch review 規範**：`stable-kernel-rules.rst` 明文禁止改變 `EXPORT_SYMBOL` 簽章、struct 重排、刪除 export 等。
- 想 diff 的人自己跑 [libabigail](https://sourceware.org/libabigail/) 的 `abidiff` / `kmidiff`。

**Greg 不跑 STG，他靠流程 + MODVERSIONS CRC**。
這是 `dkms-verifier` 的「**CRC layer**」原始來源 — `check_module.sh` 跑的就是 modversion 比對。

參考：
- `Documentation/process/stable-kernel-rules.rst`
- https://www.kernel.org/category/releases.html

### 流派 2: Android Common Kernel (ACK) + GKI

**目標**：讓 partner（Qualcomm、MediaTek、Samsung、Pixel...）寫的 vendor module，
不需要每個 LTS 升級都重新 port，只要遵守 GKI 公布的 KMI 就保證能載入。

這是**自動化、tag-driven、whitelist-scoped** 的 ABI 治理。

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

關鍵概念：

| 概念 | Android 怎麼做 | dkms-verifier 怎麼用 |
|---|---|---|
| **Per-release ABI snapshot** | 每次 push tag 時，CI 重 build kernel + 抽出新的 `abi.stg`，對舊版 diff，違反就 reject。 | 每個 release tag 跑一次 `make release-branch`，產 `releases/<tag>/report.html`。 |
| **Symbol whitelist scope** | partner 註冊「我會用到的 symbol」到 `symbols/<partner>`，ABI 只在這些 symbol 上強制。 | 自動：`modprobe --dump-modversions` 抽 module 真正用到的 symbol 當 whitelist。 |
| **Allowed breaks** | `abi.stg.allowed_breaks` 列出已批准的破壞，CI 看到列表內的 diff 就放行。 | 我們不做 — DKMS context 只問「能不能載」，每個 break 都要報。 |
| **Tooling** | Google [STG](https://github.com/google/stg) (`stg`, `stgdiff`)，from BTF/DWARF，比 libabigail 快很多。 | 用 libabigail 的 `kmidiff` — `apt install abigail-tools` 一行搞定，跨 distro 通用。 |
| **CI 接點** | Bazel + Kleaf：`tools/bazel run //common:kernel_aarch64_abi_dist`。 | Jenkins + Makefile：`make release-branch BRANCH=...`。 |

參考：
- Android GKI 總覽：https://source.android.com/docs/core/architecture/kernel/generic-kernel-image
- KMI symbol list 規範：https://source.android.com/docs/core/architecture/kernel/symbols
- STG repo：https://github.com/google/stg
- Kleaf (Bazel 包裝層) 文件：在 Android Common Kernel 樹裡 `build/kernel/kleaf/README.md`

---

## 兩流派合起來 → dkms-verifier

`dkms-verifier` 借 Android GKI 的**自動化框架**和 Greg KH 的**MODVERSIONS CRC 主力**，組合成第三個 use case：

> 「我有 OOT kernel，想在 Ubuntu LTS 上跑 — 我的 module 能不能變成 DKMS package？」

### 從 Android 借來的東西

1. **「Track ABI per release tag」** — `releases/<tag>/` 目錄結構就是這個概念。
   GKI 一個 tag = 一份 `abi.stg`；我們一個 tag = 一份 `summary.csv` + `report.html`。

2. **Symbol whitelist scope** — Android 的 `symbols/<partner>` → 我們的「module 自己用 `nm -u` 抽出來的 symbol set」。
   兩者都解決同一個問題：**全 kernel diff 噪音太多，要先框小範圍**。

3. **CRC vs Real-missing 的二層分層** — 跟 Android「symbol 還在但 type 變了」vs「symbol 完全不見」的分類同源。

4. **`allowed_breaks` 的精神** — 我們在 `run_release.sh` 裡 hardcode 一組 kernel-internal renames
   （`*_noprof`, `__ref_stack_chk_guard`, `__fortify_panic`...）當「允許清單」，
   不算進 real-missing。等於精簡版的 `abi.stg.allowed_breaks`。

5. **Tag-driven CI** — `Jenkinsfile` 接 `copyArtifacts` + `publishHTML`，
   跟 Android 的「每個 tag push → ABI job 跑 → 報告 publish」流程一比一。

### 從 Greg KH 借來的東西

1. **MODVERSIONS CRC 是真正能擋 `insmod` 的東西** — 我們的「CRC mismatch」就是這層。
2. **`Module.symvers` 是檔案契約** — refresh_targets.sh 抓的就是這個檔。
3. **「不要過度 engineer」的精神** — Greg 不跑 STG 也活得好，所以我們也決定先不跑 STG，
   用 `kmidiff`（一個 apt 指令）就能 cover 大部分需求。

### 我們改了什麼

| 改動 | 原因 |
|---|---|
| `stg` / `stgdiff` → `kmidiff` (libabigail) | apt 一行裝完，不用 build。STG 在 Android 工具鏈外不好用。 |
| 靜態 partner symbol list → 動態從 `.ko` 抽 | OOT use case 不知道哪家 partner，但每次都有具體 module。 |
| 不做 `abi.stg.allowed_breaks` | DKMS 角度每個 break 都重要，不能「批准」掉。 |
| 加「real-missing 過濾」 | Greg 跟 Android 都不需要這個，因為他們重編 kernel；我們是 DKMS（重編 module 但不重編 kernel），所以要區分「rebuild 救得到」vs「救不到」。 |
| 加「對多個 Ubuntu target 同時 diff」 | Android 一個 release 對應一個 KMI；我們可能要同時對 6.8 GA + 6.17 HWE，所以 `targets.conf` 是 list。 |

---

## 一句話總結

> **Greg KH 的 stable kernel 流程**告訴我們「modversion CRC 是真正在守的東西」。
> **Android GKI** 告訴我們「ABI 治理可以自動化、可以 tag-driven、可以用 symbol whitelist 框 scope」。
> **`dkms-verifier`** = (Greg 的 CRC) × (Android 的自動化) × (DKMS 的 real-missing 過濾)。

---

## 想看真品

如果你想看 Android 是怎麼做的：

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

跟 `dkms-verifier` 對著看，會發現：

- 我們的 `targets/<id>/staged/Module.symvers` ≈ Android 的 `gki/aarch64/abi.stg`（簡化版）
- 我們的 `releases/<tag>/analysis/<mod>-vs-<target>-real-missing.txt` ≈ Android 的 ABI diff report
- 我們的 `targets.conf` ≈ Android 的 `symbols/` 目錄概念（但反過來，由 target 決定範圍而不是 module）
- 我們的 `Makefile release-branch` target ≈ Android 的 `tools/bazel run //common:kernel_aarch64_abi_dist`

---

## 延伸閱讀

- **GKI overview** — https://source.android.com/docs/core/architecture/kernel/generic-kernel-image
- **KMI versioning** — https://source.android.com/docs/core/architecture/kernel/kmi-versioning
- **STG paper / talk** — https://lpc.events/event/16/contributions/1180/
- **libabigail kmidiff** — `man kmidiff` 或 https://sourceware.org/libabigail/manual/kmidiff.html
- **Greg KH stable rules** — `Documentation/process/stable-kernel-rules.rst` in any kernel tree
- **modversions explained** — `Documentation/kbuild/modules.rst` in kernel tree

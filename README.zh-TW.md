# dkms-verifier

> Languages: [English](README.md) · [简体中文](README.zh-CN.md) · **繁體中文**
>
> **第一次使用？** 看 [TUTORIAL.zh-TW.md](TUTORIAL.zh-TW.md) — 給初學者的 step-by-step 教學。
>
> **想了解方法論從哪來？** 看 [BACKGROUND.zh-TW.md](BACKGROUND.zh-TW.md) — 這套工具如何借用 Greg KH 的 stable-kernel 規則與 Android GKI 的 ABI 工具鏈。

判斷你針對**自己的** OOT (out-of-tree) kernel 編出來的 module，能不能在
**目標** kernel（Ubuntu GA / HWE）上載入，以及它能不能活成一個 DKMS 模組 —
按 release tag 可重複執行。

這個框架來自一次實戰分析：在某 upstream LTS base 與 Intel kernel-staging
branch 之間有 335 個 OOT patches，要回答「這次 release 改到的每個 driver，
能不能在 Ubuntu 24.04 GA (kernel 6.8) 與 HWE (kernel 6.17) 上活成 DKMS？」
框架可推廣到任意 OOT 樹 + 任意一組 Canonical kernel target。

## 它做什麼

- **發現** OOT release tag（`<base>` 與 `<head>` 之間的 commits）改到了哪些 `.ko`。
- **比對** 每個 module 的 MODVERSIONS 表，對照 `targets.conf` 列出的每個 Ubuntu KMI baseline。
- **分類** 每對 (module, target) 為 DKMS OK / with-shims / high risk / very-high-risk，依據是 real-missing API 數量。
- **產出** 一份獨立的 HTML 報告 `releases/<tag>/report.html`。
- **比較** 相鄰兩個 release 之間的 regression / improvement。

## Quick start

```sh
# 1. 設定 Ubuntu dbgsym repo（一次性）：
CODENAME=$(lsb_release -cs)
echo "deb http://ddebs.ubuntu.com $CODENAME main restricted universe multiverse" \
  | sudo tee /etc/apt/sources.list.d/ddebs.list
echo "deb http://ddebs.ubuntu.com $CODENAME-updates main restricted universe multiverse" \
  | sudo tee -a /etc/apt/sources.list.d/ddebs.list
sudo apt install ubuntu-dbgsym-keyring abigail-tools binutils kmod dpkg-dev zstd xz-utils
sudo apt update

# 2. 快取 targets.conf 列出的 Ubuntu baselines：
make refresh-targets

# 3. 跑一份 release 報告。最簡入口 — 給它一個 branch：
make release-branch \
    BRANCH=origin/6.18/linux \
    SRC=/path/to/kernel-tree

# 4. 開啟報告：
xdg-open releases/lts-v6.18.27-linux-260507T092754Z/report.html
```

`examples/` 下放了兩份範例報告 — 一個 LTS 6.18 branch、一個
mainline-preprod 7.0 branch。可以看 `report.html`、`summary.csv`、
`modules.txt`、`analysis/` 長什麼樣。

branch tip 必須有 release tag（`lts-v*-linux-*` 或
`mainline-preprod-v*-linux-*`）；`scripts/resolve_branch.sh` 會自動推導
`TAG / BASE / HEAD`。

如果你已經有 prebuilt module artifact（deb / tarball / 目錄）：

```sh
make release-branch \
    BRANCH=origin/6.18/linux \
    SRC=/path/to/kernel-tree \
    ARTIFACT=/path/to/linux-modules.tar.zst
```

不給 `ARTIFACT` 時框架會從 `/lib/modules/$(uname -r)/kernel` 讀 `.ko`，
也就是當前 running kernel — 僅當 running kernel **就是** OOT build 時才有用。

## Tag 命名慣例

`scripts/parse_tag.sh` 從 tag 抽出 OOT baseline (`BASE`)：

| Tag                                              | BASE      | STREAM             |
|---|---|---|
| `lts-v6.18.27-linux-260507T092754Z`              | `v6.18.27`| `lts`              |
| `mainline-preprod-v7.0-linux-260513T080332Z`     | `v7.0`    | `mainline-preprod` |

如果 tag 不在當前 checkout 的 branch（例如它指向 `origin/6.18/linux`，
但工作樹在另一個 branch），明確傳 `HEAD=<rev>`。CI 一定要這樣做。

## 加新的 Canonical release 當 target

編輯 `targets.conf`：

```
ubuntu-24.04-ga       6.8.0-31-generic       Ubuntu 24.04 GA (kernel 6.8)
ubuntu-24.04-hwe      6.17.0-23-generic      Ubuntu 24.04 HWE (kernel 6.17)
ubuntu-25.04          6.14.0-19-generic      Ubuntu 25.04 (plucky)
```

然後：
```sh
make refresh-targets
make release TAG=... SRC=... HEAD=...
```
HTML 報告會自動多一欄 — 不用改 script。

## ABI 三層是什麼意思

| 層 | 由誰強制 | 範圍 |
|---|---|---|
| **Symbol presence** | `insmod` | target 是否 export 了 module 引入的每個 symbol？ |
| **CRC match** | `insmod` (MODVERSIONS) | CRC 一致代表 binary 相容 — DKMS 重編一定會拿到新的 CRC，所以對 DKMS 分析而言 CRC mismatch 是雜訊。 |
| **Type-level ABI** | DKMS 重編時 由 compiler | 函式簽名、struct layout。會讓 DKMS *編不過*。 |

本框架專注 layer 1 + 2，layer 1（"real-missing"）才是真正的 DKMS blocker。
Layer 3 (`kmidiff`、`stgdiff`) 直接呼叫 `check_module.sh --my-vmlinux` 時支援，
但還沒接進 per-release pipeline。

### "Real-missing" 過濾

HTML 會剝掉一小撮不會真正破壞 DKMS 重編的 kernel-internal renames：

```
*_noprof                   # mem profiling rename (6.10+)
__ref_stack_chk_guard      # stack protector
__fortify_panic            # FORTIFY_SOURCE
__preempt_count            # preempt counter
const_current_task         # current_task constification
```

如果你的 kernel 有更多這種 rename，去 `scripts/run_release.sh` 加。

## Per-release 輸出 layout

```
releases/<tag>/
├── manifest.txt                  # tag, base, head, generation timestamp
├── modules.txt                   # 從 diff 發現的 modules
├── summary.csv                   # 主表
├── report.html                   # 給人看的報告
├── ko/                           # 此次跑用的解壓 .ko 檔
├── analysis/
│   └── <module>-vs-<target>-real-missing.txt   # 過濾後的 API 列表
└── raw/
    └── <module>-vs-<target>/
        ├── used_syms.txt
        ├── missing_symbols.txt
        ├── crc_mismatch.txt
        └── used_crcs.txt
```

## 比較兩個 release

```sh
make compare A=lts-v6.18.27-linux-260507T092754Z \
             B=lts-v6.18.27-linux-260513T080332Z
```

輸出：(module, target, A_real_missing, B_real_missing, delta, status) 的表 —
每行對應一對數字有變動的 module/target。

## Jenkins 整合

`dkms-verifier` 設計為 kernel CI pipeline 中的**其中一個 job**，不負責 build kernel；
上游 Jenkins build job 應該 build OOT kernel 並 archive modules artifact。

`Jenkinsfile` 流程：

1. Checkout dkms-verifier repo。
2. 把 `$BRANCH` 解析為 `TAG / BASE / HEAD`。branch tip 沒 release tag 直接 fail。
3. （可選）刷新 Ubuntu baselines。
4. `copyArtifacts` 從 `$UPSTREAM_JOB` 拉 modules tarball / deb。
5. `make release-branch ARTIFACT=<拷過來的 artifact>`。
6. 跟上一份 release diff。
7. Archive `releases/<tag>/` 並 publish HTML 報告。

需要的 Jenkins 參數：

| Parameter | 範例 | 用途 |
|---|---|---|
| `BRANCH` | `origin/6.18/linux` | 評估哪個 branch |
| `KERNEL_SRC` | `/srv/ci/kernel-lts-staging` | agent 上的 OOT kernel git 樹 |
| `UPSTREAM_JOB` | `kernel-build-oot` | 產生 modules 的 build job |
| `UPSTREAM_BUILD_SELECTOR` | `lastSuccessful` | 拷貝哪一次 build |
| `UPSTREAM_ARTIFACT_GLOB` | `linux-modules-*.tar.*` | 抓什麼檔 |

**上游 artifact 契約**：upstream build job 必須 archive 一個
`import_modules.sh` 認得的 artifact：

- 包含 `lib/modules/<ver>/kernel/` 子樹的目錄，或
- `linux-image-*.deb` / `linux-modules-*.deb`，或
- 上述兩者之一的 `.tar` / `.tar.gz` / `.tar.xz` / `.tar.zst`。

推薦形態：`linux-modules-<branch>.tar.zst`，裡面是 `lib/modules/<ver>/kernel/...`。

**需要的 Jenkins plugins**：Pipeline、Git、Copy Artifact、HTML Publisher。
可選：Slack / Email Extension 用於 failure 通知（`post { failure { ... } }` 裡有註解掉的模板）。

## 檔案清單

| 檔案 | 用途 |
|---|---|
| `Makefile` | 頂層入口：`release`、`release-branch`、`refresh-targets`、`compare` |
| `Jenkinsfile` | CI pipeline |
| `targets.conf` | Ubuntu KMI baselines（在這裡擴充） |
| `scripts/parse_tag.sh` | Tag → BASE/STREAM/STAMP |
| `scripts/resolve_branch.sh` | Branch → (TAG, BASE, HEAD) |
| `scripts/discover_modules.sh` | Diff → `.ko` 名字列表 |
| `scripts/refresh_targets.sh` | Apt-fetch 並 stage 所有 targets |
| `scripts/import_modules.sh` | 把上游 job 的 artifact stage 成 kmods 樹 |
| `scripts/run_release.sh` | Tag → 完整報告（orchestrator） |
| `scripts/build_report.sh` | summary.csv → report.html |
| `scripts/diff_releases.sh` | A/B summary delta |
| `check_module.sh` | 單 module CRC 檢查 + 選用 kmidiff |
| `fetch_ubuntu_kernel.sh` | 把一個 Ubuntu kernel stage 成 target |

## 注意事項

- `discover_modules.sh` 是啟發式的 — Kbuild 可能藏在 Kconfig 或動態 obj-
  指派後面。`run_release.sh` 預設帶 `--verify`，過濾掉在 running tree 裡
  不存在 `.ko` 的名字。
- CRC layer 需要 OOT kernel build 開 `CONFIG_MODVERSIONS=y`。
- Module signing / Secure Boot lockdown 是另一個問題 — ABI 檢查通過不代表
  module 能在 lockdown 系統上載入。
- `kmidiff`（type-level diff）已經接到 `check_module.sh`，但還沒接進
  `run_release.sh`。要抓 CRC 看不出的 struct layout 改動可以加進去。

# 實習生 step-by-step 教學

這份是給第一次用 `dkms-verifier` 的人看的。所有指令都可以直接複製貼上。

如果有不懂的字（例如「KMI」「DKMS」「Module.symvers」），先別管，照做就對了。最後有名詞解釋。

---

## 你會做什麼

拿到一個 OOT kernel 的 branch 名字，跑一個指令，產出一份 HTML 報告，告訴你：
**「這次 release 改到的每個 driver，能不能變成 DKMS 跑在 Ubuntu 24.04 上？」**

---

## 你需要什麼

- 一台 Ubuntu 24.04 機器（或 VM）
- sudo 權限
- 大約 30 分鐘第一次安裝
- 之後每次跑只要 1-2 分鐘

---

## Step 1 — 裝工具

```sh
sudo apt update
sudo apt install -y git make abigail-tools binutils kmod dpkg-dev zstd xz-utils lsb-release
```

驗證：

```sh
which kmidiff modprobe dpkg-deb make zstd
```

每一行都要印出路徑。如果 `kmidiff` 找不到，代表 `abigail-tools` 沒裝好。

---

## Step 2 — clone repo

```sh
cd ~
git clone https://github.com/krispan-intel/dkms-verifier.git
cd dkms-verifier
```

---

## Step 3 — 設定 Ubuntu dbgsym repo（一次性）

我們要從 Ubuntu archive 抓 kernel 的 `Module.symvers`，需要先加 dbgsym source。

```sh
CODENAME=$(lsb_release -cs)
echo "deb http://ddebs.ubuntu.com $CODENAME main restricted universe multiverse" \
  | sudo tee /etc/apt/sources.list.d/ddebs.list
echo "deb http://ddebs.ubuntu.com $CODENAME-updates main restricted universe multiverse" \
  | sudo tee -a /etc/apt/sources.list.d/ddebs.list
sudo apt install -y ubuntu-dbgsym-keyring
sudo apt update
```

如果 `apt update` 出現 GPG 錯誤，再跑一次 `sudo apt install -y ubuntu-dbgsym-keyring`。

---

## Step 4 — 抓 Ubuntu kernel baselines

```sh
make refresh-targets
```

這會下載 `targets.conf` 裡列的每個 Ubuntu kernel package。第一次大概要 2-3 分鐘、~150 MB 流量。

成功的話會看到：

```
Cached targets:
  ubuntu-24.04-ga        symvers=30190 lines +vmlinux
  ubuntu-24.04-hwe       symvers=32890 lines +vmlinux
```

之後重跑 `make refresh-targets` 會 skip 已下載的，幾秒鐘就好。

---

## Step 5 — 拿 OOT kernel tree

你的 mentor 會給你一個內部 git URL（很長那種）。clone 到另一個目錄：

```sh
cd ~
git clone <你的-mentor-給的-URL> kernel-tree
```

> ⚠️ 記得要 clone 到 `dkms-verifier` 以外的地方。把 kernel tree 放在 `~/kernel-tree` 是 OK 的。

---

## Step 6 — 找 branch 名字

mentor 會給你一個 branch 名稱，常見的長這樣：

- `origin/6.18/linux`（LTS）
- `mlt-staging/mainline-tracking/v7.0`（mainline-preprod）

先確認這 branch tip 有沒有 release tag：

```sh
cd ~/kernel-tree
git tag --points-at <branch-name> | grep -E '^(lts-v|mainline-preprod-v)'
```

例：

```sh
git tag --points-at origin/6.18/linux | grep -E '^(lts-v|mainline-preprod-v)'
```

如果有東西吐出來（例如 `lts-v6.18.27-linux-260507T092754Z`），✅ 可以繼續。

如果什麼都沒有 ❌：跟 mentor 說「這 branch tip 沒有合格的 release tag」。

---

## Step 7 — 拿 module artifact（很重要）

`dkms-verifier` 不會自己 build kernel。你需要從**上游 Jenkins build job** 下載別人 build 好的 modules。問 mentor：

> 「請問 OOT kernel 的 modules artifact 在哪個 Jenkins job 找？」

通常會是 Jenkins job 的 archive 區一個檔案，副檔名是其中一種：
- `linux-modules-*.tar.zst`（最常見）
- `linux-modules-*.deb`
- `linux-image-*.deb`
- 一個目錄（如果用 NFS / 共用 storage）

下載到本機：

```sh
mkdir -p ~/Downloads/oot
cd ~/Downloads/oot
# 用 wget / scp / 從 Jenkins web UI 下載都可以
```

---

## Step 8 — 跑報告

```sh
cd ~/dkms-verifier
make release-branch \
  BRANCH=origin/6.18/linux \
  SRC=~/kernel-tree \
  ARTIFACT=~/Downloads/oot/linux-modules-XXX.tar.zst
```

把 `BRANCH=...` 跟 `ARTIFACT=...` 改成你自己的。

跑成功會看到：

```
[release-branch] BRANCH=origin/6.18/linux TAG=lts-v6.18.27-linux-... BASE=v6.18.27 HEAD=...
[13:48:23] discovering modules (v6.18.27..722b023c...)
[13:48:31]   34 modules to check
...
[13:48:33] done → /home/.../releases/lts-v6.18.27-linux-260507T092754Z
```

---

## Step 9 — 看報告

```sh
xdg-open releases/<那個-TAG>/report.html
```

例：

```sh
xdg-open releases/lts-v6.18.27-linux-260507T092754Z/report.html
```

要先看的就是這份 HTML。

---

## Step 10 — 怎麼讀報告

### 最上面 TL;DR

兩張卡片，一張對應一個 Ubuntu target：

```
Ubuntu 24.04 GA (kernel 6.8)         Ubuntu 24.04 HWE (kernel 6.17)
12 DKMS OK   8 with shims  4 high    32 DKMS OK  2 with shims  0 high
```

### 中間 Per-module verdicts 表格

每個 module 一行。`real-missing` 是真正會擋 DKMS 的 API 數量。看 verdict 那欄就好：

| 顏色 | 意思 |
|---|---|
| 🟢 **DKMS OK** | 直接重編就好，0 個 API 缺 |
| 🟡 **DKMS with shims** | 1-5 個 API 缺，要寫 compat wrapper |
| 🔴 **High risk** | 6-30 個缺，要 backport 大塊 |
| 🔴 **Very high risk** | 30+ 個缺，建議放棄 DKMS、直接 ship custom kernel |

點 module 名字會跳到下面的 missing API 細節。

### 最下面 Per-module detail

每個 module 一個 collapsible block，列出對每個 Ubuntu target 缺了哪些 API。
這就是你回報給 mentor 的內容。

---

## 你的工作怎麼回報

開個 ticket / 寫 mail，貼這幾項：

```
Branch:       origin/6.18/linux
Tag:          lts-v6.18.27-linux-260507T092754Z
Modules touched: 34
DKMS OK @ 24.04 GA:         12
DKMS with shims @ 24.04 GA:  8
High risk @ 24.04 GA:        4   ← 這幾個要列出來
Very high risk @ 24.04 GA:   0

Report: <把 report.html 上傳到 share drive 或附在 ticket>
```

---

## 故障排除

### `make refresh-targets` 下載失敗

```
E: Unable to locate package linux-image-unsigned-X.Y.Z-XX-generic-dbgsym
```

→ Step 3 的 dbgsym repo 沒設好。重做 Step 3，特別是 `sudo apt update`。

### `ERROR: no release tag found at <branch>`

→ branch tip 沒 release tag。回 Step 6 確認 branch 名字、跟 mentor 確認。

### `ERROR: kmods dir not found`

→ 沒給 `ARTIFACT=`、或路徑打錯。回 Step 7、Step 8。

### `ERROR: BASE rev 'vX.Y.Z' not found in <SRC>`

→ kernel tree 沒 fetch 到上游 tag。試：
```sh
cd ~/kernel-tree
git fetch --tags
```

### 跑完只有 0 modules

→ branch 跟 base 沒差別，或 branch 名字 typo。檢查：
```sh
cd ~/kernel-tree
git log --oneline v6.18.27..origin/6.18/linux | head
```
有東西才代表確實有 patches。

---

## 不靠 OOT tree 先驗工具有沒有壞（demo）

還沒拿到 OOT kernel access？先用 running kernel demo 一下：

```sh
cd ~/dkms-verifier

# 1. 拿一個系統現有的 .ko
cp /lib/modules/$(uname -r)/kernel/drivers/edac/igen6_edac.ko.zst /tmp/
zstd -d /tmp/igen6_edac.ko.zst -o /tmp/igen6_edac.ko

# 2. 對 Ubuntu 24.04 GA (6.8) 跑 ABI check
./check_module.sh \
  --module /tmp/igen6_edac.ko \
  --target targets/ubuntu-24.04-ga/staged \
  --report /tmp/demo
```

應該看到類似：

```
=== Symbol / CRC check ===
  expected:     49 symbols
  missing:      2
  CRC mismatch: 47

RESULT: FAIL — module will not load on target kernel.
```

這證明工具鏈 OK，剩下就等 OOT branch 跟 artifact。

---

## 名詞解釋（背景）

| 詞 | 意思 |
|---|---|
| **OOT** | Out-of-tree。指公司內部維護、還沒 upstream 的 kernel patches。 |
| **DKMS** | Dynamic Kernel Module Support。讓 module 在不同 kernel 重編而不用全部重 build。 |
| **KMI** | Kernel Module Interface。kernel 跟 module 之間的 ABI 邊界。 |
| **Module.symvers** | 一份檔案，列出 kernel 每個 export symbol 的 CRC（版本指紋）。`insmod` 載入 module 時會比對這個。 |
| **CRC mismatch** | symbol 在但版本對不上。重編就會修好（DKMS 就是這個 use case）。 |
| **Real-missing** | symbol 整個不在了。重編也救不了，必須 backport API 或 patch source。 |

---

## 接下來想學更多？

- 看 `README.md` — 完整 framework 文件
- 看 `examples/` — 兩份真實 release 的範例 report
- 看 `Jenkinsfile` — 整個自動化的 CI pipeline
- 跑 `make help` — 列出所有可用指令

有問題問 mentor，或開 issue：
https://github.com/krispan-intel/dkms-verifier/issues

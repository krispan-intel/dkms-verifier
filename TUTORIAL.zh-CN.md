# 初学者 step-by-step 教程

> Languages: [English](TUTORIAL.md) · **简体中文** · [繁體中文](TUTORIAL.zh-TW.md)

这份是给第一次用 `dkms-verifier`、对 kernel/ABI 没什么背景的人看的。所有命令都可以直接复制粘贴。

如果有不懂的词（例如「KMI」「DKMS」「Module.symvers」），先别管，照做就对了。最后有名词解释。

---

## 你会做什么

拿到一个 OOT kernel 的 branch 名字，跑一条命令，生成一份 HTML 报告，告诉你：
**「这次 release 改到的每个 driver，能不能变成 DKMS 跑在 Ubuntu 24.04 上？」**

---

## 你需要什么

- 一台 Ubuntu 24.04 机器（或 VM）
- sudo 权限
- 第一次安装大约 30 分钟
- 之后每次跑只要 1-2 分钟

---

## Step 1 — 装工具

```sh
sudo apt update
sudo apt install -y git make abigail-tools binutils kmod dpkg-dev zstd xz-utils lsb-release
```

验证：

```sh
which kmidiff modprobe dpkg-deb make zstd
```

每一行都要输出路径。如果 `kmidiff` 找不到，说明 `abigail-tools` 没装好。

---

## Step 2 — clone repo

```sh
cd ~
git clone https://github.com/krispan-intel/dkms-verifier.git
cd dkms-verifier
```

---

## Step 3 — 配置 Ubuntu dbgsym repo（一次性）

我们要从 Ubuntu archive 抓 kernel 的 `Module.symvers`，需要先加 dbgsym source。

```sh
CODENAME=$(lsb_release -cs)
echo "deb http://ddebs.ubuntu.com $CODENAME main restricted universe multiverse" \
  | sudo tee /etc/apt/sources.list.d/ddebs.list
echo "deb http://ddebs.ubuntu.com $CODENAME-updates main restricted universe multiverse" \
  | sudo tee -a /etc/apt/sources.list.d/ddebs.list
sudo apt install -y ubuntu-dbgsym-keyring
sudo apt update
```

如果 `apt update` 出现 GPG 错误，再跑一次 `sudo apt install -y ubuntu-dbgsym-keyring`。

---

## Step 4 — 抓 Ubuntu kernel baselines

```sh
make refresh-targets
```

这会下载 `targets.conf` 里列的每个 Ubuntu kernel package。第一次大概要 2-3 分钟、~150 MB 流量。

成功的话会看到：

```
Cached targets:
  ubuntu-24.04-ga        symvers=30190 lines +vmlinux
  ubuntu-24.04-hwe       symvers=32890 lines +vmlinux
```

之后重跑 `make refresh-targets` 会 skip 已下载的，几秒钟就好。

---

## Step 5 — 拿 OOT kernel tree

你的 mentor 会给你一个内部 git URL（很长那种）。clone 到另一个目录：

```sh
cd ~
git clone <你的-mentor-给的-URL> kernel-tree
```

> ⚠️ 记得要 clone 到 `dkms-verifier` 以外的地方。把 kernel tree 放在 `~/kernel-tree` 是 OK 的。

---

## Step 6 — 找 branch 名字

mentor 会给你一个 branch 名称，常见的长这样：

- `origin/6.18/linux`（LTS）
- `mlt-staging/mainline-tracking/v7.0`（mainline-preprod）

先确认这 branch tip 有没有 release tag：

```sh
cd ~/kernel-tree
git tag --points-at <branch-name> | grep -E '^(lts-v|mainline-preprod-v)'
```

例：

```sh
git tag --points-at origin/6.18/linux | grep -E '^(lts-v|mainline-preprod-v)'
```

如果有东西吐出来（例如 `lts-v6.18.27-linux-260507T092754Z`），✅ 可以继续。

如果什么都没有 ❌：跟 mentor 说「这个 branch tip 没有合格的 release tag」。

---

## Step 7 — 拿 module artifact（很重要）

`dkms-verifier` 不会自己 build kernel。你需要从**上游 Jenkins build job** 下载别人 build 好的 modules。问 mentor：

> 「请问 OOT kernel 的 modules artifact 在哪个 Jenkins job 里找？」

通常是 Jenkins job archive 区的一个文件，扩展名是其中一种：
- `linux-modules-*.tar.zst`（最常见）
- `linux-modules-*.deb`
- `linux-image-*.deb`
- 一个目录（如果用 NFS / 共享 storage）

下载到本机：

```sh
mkdir -p ~/Downloads/oot
cd ~/Downloads/oot
# 用 wget / scp / 从 Jenkins web UI 下载都可以
```

---

## Step 8 — 跑报告

```sh
cd ~/dkms-verifier
make release-branch \
  BRANCH=origin/6.18/linux \
  SRC=~/kernel-tree \
  ARTIFACT=~/Downloads/oot/linux-modules-XXX.tar.zst
```

把 `BRANCH=...` 跟 `ARTIFACT=...` 改成你自己的。

跑成功会看到：

```
[release-branch] BRANCH=origin/6.18/linux TAG=lts-v6.18.27-linux-... BASE=v6.18.27 HEAD=...
[13:48:23] discovering modules (v6.18.27..722b023c...)
[13:48:31]   34 modules to check
...
[13:48:33] done → /home/.../releases/lts-v6.18.27-linux-260507T092754Z
```

---

## Step 9 — 看报告

```sh
xdg-open releases/<那个-TAG>/report.html
```

例：

```sh
xdg-open releases/lts-v6.18.27-linux-260507T092754Z/report.html
```

这份 HTML 就是要交付的成果。

---

## Step 10 — 怎么读报告

### 最上面 TL;DR

两张卡片，一张对应一个 Ubuntu target：

```
Ubuntu 24.04 GA (kernel 6.8)         Ubuntu 24.04 HWE (kernel 6.17)
12 DKMS OK   8 with shims  4 high    32 DKMS OK  2 with shims  0 high
```

### 中间 Per-module verdicts 表格

每个 module 一行。`real-missing` 是真正会拦下 DKMS 的 API 数量。看 verdict 那一栏就够：

| 颜色 | 含义 |
|---|---|
| 🟢 **DKMS OK** | 直接重编就好，0 个 API 缺 |
| 🟡 **DKMS with shims** | 1-5 个 API 缺，要写 compat wrapper |
| 🔴 **High risk** | 6-30 个缺，要 backport 大块 |
| 🔴 **Very high risk** | 30+ 个缺，建议放弃 DKMS、直接 ship custom kernel |

点 module 名字会跳到下面的 missing API 详情。

### 最下面 Per-module detail

每个 module 一个 collapsible block，列出对每个 Ubuntu target 缺了哪些 API。
这就是你回报给 mentor 的内容。

---

## 工作怎么回报

开个 ticket / 发邮件，贴这几项：

```
Branch:                      origin/6.18/linux
Tag:                         lts-v6.18.27-linux-260507T092754Z
Modules touched:             34
DKMS OK @ 24.04 GA:          12
DKMS with shims @ 24.04 GA:   8
High risk @ 24.04 GA:         4   ← 这几个要列出来
Very high risk @ 24.04 GA:    0

Report: <把 report.html 上传到 share drive 或附在 ticket 里>
```

---

## 故障排除

### `make refresh-targets` 下载失败

```
E: Unable to locate package linux-image-unsigned-X.Y.Z-XX-generic-dbgsym
```

→ Step 3 的 dbgsym repo 没设好。重做 Step 3，特别是 `sudo apt update`。

### `ERROR: no release tag found at <branch>`

→ branch tip 没 release tag。回 Step 6 确认 branch 名字、跟 mentor 确认。

### `ERROR: kmods dir not found`

→ 没给 `ARTIFACT=`、或路径打错。回 Step 7、Step 8。

### `ERROR: BASE rev 'vX.Y.Z' not found in <SRC>`

→ kernel tree 没 fetch 到上游 tag。试：
```sh
cd ~/kernel-tree
git fetch --tags
```

### 跑完只有 0 modules

→ branch 跟 base 没差别，或 branch 名字 typo。检查：
```sh
cd ~/kernel-tree
git log --oneline v6.18.27..origin/6.18/linux | head
```
有东西才代表确实有 patches。

---

## 不靠 OOT tree 先验工具有没有坏（demo）

还没拿到 OOT kernel access？先用 running kernel demo 一下：

```sh
cd ~/dkms-verifier

# 1. 拿一个系统现有的 .ko
cp /lib/modules/$(uname -r)/kernel/drivers/edac/igen6_edac.ko.zst /tmp/
zstd -d /tmp/igen6_edac.ko.zst -o /tmp/igen6_edac.ko

# 2. 对 Ubuntu 24.04 GA (6.8) 跑 ABI check
./check_module.sh \
  --module /tmp/igen6_edac.ko \
  --target targets/ubuntu-24.04-ga/staged \
  --report /tmp/demo
```

应该看到类似：

```
=== Symbol / CRC check ===
  expected:     49 symbols
  missing:      2
  CRC mismatch: 47

RESULT: FAIL — module will not load on target kernel.
```

这证明工具链 OK，剩下就等 OOT branch 跟 artifact。

---

## 名词解释（背景）

| 词 | 含义 |
|---|---|
| **OOT** | Out-of-tree。指公司内部维护、还没 upstream 的 kernel patches。 |
| **DKMS** | Dynamic Kernel Module Support。让 module 在不同 kernel 重编而不用全部重 build。 |
| **KMI** | Kernel Module Interface。kernel 跟 module 之间的 ABI 边界。 |
| **Module.symvers** | 一份文件，列出 kernel 每个 export symbol 的 CRC（版本指纹）。`insmod` 加载 module 时会比对这个。 |
| **CRC mismatch** | symbol 在但版本对不上。重编就会修好（DKMS 就是这个 use case）。 |
| **Real-missing** | symbol 整个不在了。重编也救不了，必须 backport API 或 patch source。 |

---

## 接下来想学更多？

- 看 `README.md` — 完整 framework 文档
- 看 `BACKGROUND.md` — 这套工具的方法论从哪来（Greg KH stable kernel + Android GKI）
- 看 `examples/` — 两份真实 release 的范例 report
- 看 `Jenkinsfile` — 整套自动化的 CI pipeline
- 跑 `make help` — 列出所有可用命令

有问题问 mentor，或开 issue：
https://github.com/krispan-intel/dkms-verifier/issues

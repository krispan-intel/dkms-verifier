# dkms-verifier

> Languages: [English](README.md) · **简体中文** · [繁體中文](README.zh-TW.md)
>
> **第一次使用？** 看 [TUTORIAL.zh-CN.md](TUTORIAL.zh-CN.md) — 给初学者的 step-by-step 教程。
>
> **想了解方法论从哪来？** 看 [BACKGROUND.zh-CN.md](BACKGROUND.zh-CN.md) — 这套工具如何借用 Greg KH 的 stable-kernel 规则与 Android GKI 的 ABI 工具链。

判断你针对**自己的** OOT (out-of-tree) kernel 编出来的 module，能不能在
**目标** kernel（Ubuntu GA / HWE）上加载，以及它能不能活成一个 DKMS 模块 —
按 release tag 可重复执行。

这个框架来自一次实战分析：在某 upstream LTS base 与 Intel kernel-staging
branch 之间有 335 个 OOT patches，要回答「这次 release 改到的每个 driver，
能不能在 Ubuntu 24.04 GA (kernel 6.8) 与 HWE (kernel 6.17) 上活成 DKMS？」
框架可推广到任意 OOT 树 + 任意一组 Canonical kernel target。

## 它做什么

- **发现** OOT release tag（`<base>` 与 `<head>` 之间的 commits）改到了哪些 `.ko`。
- **比对** 每个 module 的 MODVERSIONS 表，对照 `targets.conf` 列出的每个 Ubuntu KMI baseline。
- **分类** 每对 (module, target) 为 DKMS OK / with-shims / high risk / very-high-risk，依据是 real-missing API 数量。
- **产出** 一份独立的 HTML 报告 `releases/<tag>/report.html`。
- **比较** 相邻两个 release 之间的 regression / improvement。

## Quick start

```sh
# 1. 配置 Ubuntu dbgsym repo（一次性）：
CODENAME=$(lsb_release -cs)
echo "deb http://ddebs.ubuntu.com $CODENAME main restricted universe multiverse" \
  | sudo tee /etc/apt/sources.list.d/ddebs.list
echo "deb http://ddebs.ubuntu.com $CODENAME-updates main restricted universe multiverse" \
  | sudo tee -a /etc/apt/sources.list.d/ddebs.list
sudo apt install ubuntu-dbgsym-keyring abigail-tools binutils kmod dpkg-dev zstd xz-utils
sudo apt update

# 2. 缓存 targets.conf 列出的 Ubuntu baselines：
make refresh-targets

# 3. 跑一份 release 报告。最简入口 — 给它一个 branch：
make release-branch \
    BRANCH=origin/6.18/linux \
    SRC=/path/to/kernel-tree

# 4. 打开报告：
xdg-open releases/lts-v6.18.27-linux-260507T092754Z/report.html
```

`examples/` 下放了两份示例报告 — 一个 LTS 6.18 branch、一个
mainline-preprod 7.0 branch。可以看 `report.html`、`summary.csv`、
`modules.txt`、`analysis/` 长什么样。

branch tip 必须有 release tag（`lts-v*-linux-*` 或
`mainline-preprod-v*-linux-*`）；`scripts/resolve_branch.sh` 会自动推导
`TAG / BASE / HEAD`。

如果你已经有 prebuilt module artifact（deb / tarball / 目录）：

```sh
make release-branch \
    BRANCH=origin/6.18/linux \
    SRC=/path/to/kernel-tree \
    ARTIFACT=/path/to/linux-modules.tar.zst
```

不给 `ARTIFACT` 时框架会从 `/lib/modules/$(uname -r)/kernel` 读 `.ko`，
也就是当前 running kernel — 仅当 running kernel **就是** OOT build 时才有用。

## Tag 命名约定

`scripts/parse_tag.sh` 从 tag 抽出 OOT baseline (`BASE`)：

| Tag                                              | BASE      | STREAM             |
|---|---|---|
| `lts-v6.18.27-linux-260507T092754Z`              | `v6.18.27`| `lts`              |
| `mainline-preprod-v7.0-linux-260513T080332Z`     | `v7.0`    | `mainline-preprod` |

如果 tag 不在当前 checkout 的 branch（例如它指向 `origin/6.18/linux`，
但工作树在另一个 branch），明确传 `HEAD=<rev>`。CI 一定要这样做。

## 加新的 Canonical release 当 target

编辑 `targets.conf`：

```
ubuntu-24.04-ga       6.8.0-31-generic       Ubuntu 24.04 GA (kernel 6.8)
ubuntu-24.04-hwe      6.17.0-23-generic      Ubuntu 24.04 HWE (kernel 6.17)
ubuntu-25.04          6.14.0-19-generic      Ubuntu 25.04 (plucky)
```

然后：
```sh
make refresh-targets
make release TAG=... SRC=... HEAD=...
```
HTML 报告会自动多一栏 — 不用改 script。

## ABI 三层是什么意思

| 层 | 由谁强制 | 范围 |
|---|---|---|
| **Symbol presence** | `insmod` | target 是否 export 了 module 引入的每个 symbol？ |
| **CRC match** | `insmod` (MODVERSIONS) | CRC 一致代表 binary 兼容 — DKMS 重编一定会拿到新的 CRC，所以对 DKMS 分析而言 CRC mismatch 是噪音。 |
| **Type-level ABI** | DKMS 重编时 由 compiler | 函数签名、struct layout。会让 DKMS *编不过*。 |

本框架专注 layer 1 + 2，layer 1（"real-missing"）才是真正的 DKMS blocker。
Layer 3 (`kmidiff`、`stgdiff`) 直接呼叫 `check_module.sh --my-vmlinux` 时支持，
但还没接进 per-release pipeline。

### "Real-missing" 过滤

HTML 会剥掉一小撮不会真正破坏 DKMS 重编的 kernel-internal renames：

```
*_noprof                   # mem profiling rename (6.10+)
__ref_stack_chk_guard      # stack protector
__fortify_panic            # FORTIFY_SOURCE
__preempt_count            # preempt counter
const_current_task         # current_task constification
```

如果你的 kernel 有更多这种 rename，去 `scripts/run_release.sh` 加。

## Per-release 输出 layout

```
releases/<tag>/
├── manifest.txt                  # tag, base, head, generation timestamp
├── modules.txt                   # 从 diff 发现的 modules
├── summary.csv                   # 主表
├── report.html                   # 给人看的报告
├── ko/                           # 此次跑用的解压 .ko 文件
├── analysis/
│   └── <module>-vs-<target>-real-missing.txt   # 过滤后的 API 列表
└── raw/
    └── <module>-vs-<target>/
        ├── used_syms.txt
        ├── missing_symbols.txt
        ├── crc_mismatch.txt
        └── used_crcs.txt
```

## 比较两个 release

```sh
make compare A=lts-v6.18.27-linux-260507T092754Z \
             B=lts-v6.18.27-linux-260513T080332Z
```

输出：(module, target, A_real_missing, B_real_missing, delta, status) 的表 —
每行对应一对数字有变动的 module/target。

## Jenkins 集成

`dkms-verifier` 设计为 kernel CI pipeline 中的**其中一个 job**，不负责 build kernel；
上游 Jenkins build job 应该 build OOT kernel 并 archive modules artifact。

`Jenkinsfile` 流程：

1. Checkout dkms-verifier repo。
2. 把 `$BRANCH` 解析为 `TAG / BASE / HEAD`。branch tip 没 release tag 直接 fail。
3. （可选）刷新 Ubuntu baselines。
4. `copyArtifacts` 从 `$UPSTREAM_JOB` 拉 modules tarball / deb。
5. `make release-branch ARTIFACT=<拷过来的 artifact>`。
6. 跟上一份 release diff。
7. Archive `releases/<tag>/` 并 publish HTML 报告。

需要的 Jenkins 参数：

| Parameter | 范例 | 用途 |
|---|---|---|
| `BRANCH` | `origin/6.18/linux` | 评估哪个 branch |
| `KERNEL_SRC` | `/srv/ci/kernel-lts-staging` | agent 上的 OOT kernel git 树 |
| `UPSTREAM_JOB` | `kernel-build-oot` | 产生 modules 的 build job |
| `UPSTREAM_BUILD_SELECTOR` | `lastSuccessful` | 拷贝哪一次 build |
| `UPSTREAM_ARTIFACT_GLOB` | `linux-modules-*.tar.*` | 抓什么文件 |

**上游 artifact 契约**：upstream build job 必须 archive 一个
`import_modules.sh` 认得的 artifact：

- 包含 `lib/modules/<ver>/kernel/` 子树的目录，或
- `linux-image-*.deb` / `linux-modules-*.deb`，或
- 上述两者之一的 `.tar` / `.tar.gz` / `.tar.xz` / `.tar.zst`。

推荐形态：`linux-modules-<branch>.tar.zst`，里面是 `lib/modules/<ver>/kernel/...`。

**需要的 Jenkins plugins**：Pipeline、Git、Copy Artifact、HTML Publisher。
可选：Slack / Email Extension 用于 failure 通知（`post { failure { ... } }` 里有注释掉的模板）。

## 文件清单

| 文件 | 用途 |
|---|---|
| `Makefile` | 顶层入口：`release`、`release-branch`、`refresh-targets`、`compare` |
| `Jenkinsfile` | CI pipeline |
| `targets.conf` | Ubuntu KMI baselines（在这里扩展） |
| `scripts/parse_tag.sh` | Tag → BASE/STREAM/STAMP |
| `scripts/resolve_branch.sh` | Branch → (TAG, BASE, HEAD) |
| `scripts/discover_modules.sh` | Diff → `.ko` 名字列表 |
| `scripts/refresh_targets.sh` | Apt-fetch 并 stage 所有 targets |
| `scripts/import_modules.sh` | 把上游 job 的 artifact stage 成 kmods 树 |
| `scripts/run_release.sh` | Tag → 完整报告（编排器） |
| `scripts/build_report.sh` | summary.csv → report.html |
| `scripts/diff_releases.sh` | A/B summary delta |
| `check_module.sh` | 单 module CRC 检查 + 可选 kmidiff |
| `fetch_ubuntu_kernel.sh` | 把一个 Ubuntu kernel stage 成 target |

## 注意事项

- `discover_modules.sh` 是启发式的 — Kbuild 可能藏在 Kconfig 或动态 obj-
  指派后面。`run_release.sh` 默认带 `--verify`，过滤掉在 running tree 里
  不存在 `.ko` 的名字。
- CRC layer 需要 OOT kernel build 开 `CONFIG_MODVERSIONS=y`。
- Module signing / Secure Boot lockdown 是另一个问题 — ABI 检查通过不代表
  module 能在 lockdown 系统上加载。
- `kmidiff`（type-level diff）已经接到 `check_module.sh`，但还没接进
  `run_release.sh`。要抓 CRC 看不出的 struct layout 改动可以加进去。

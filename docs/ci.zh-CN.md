# CI

**中文** | [English](ci.md)

流水线在 GitHub Actions 上构建、启动并评判固件，而它做出的每个决定都可以在没有 GitHub 的
Linux 机器上复现。本页是地图：跑哪个文件、每个阶段证明什么、一次发布要证明什么，以及 CI
允许对人说什么话。

阶段脚本本身见 [`../scripts/ci/README.md`](../scripts/ci/README.md)；驱动真机的那套见
[device-matrix.zh-CN.md](device-matrix.zh-CN.md)。

## 工作流文件与入口

`.github/workflows/` 下十七个文件。四个能发起运行，其余十三个只声明 `workflow_call`，因此
不能。

| 工作流文件 | 触发 | 产物 | 何时运行 |
|---|---|---|---|
| `ci.yml` | 推送或对 `main` 的 PR、`workflow_dispatch`（`stage`、`upstream_version`）、`workflow_call` | 自身没有：它调用各阶段 | 日常验证，或失败运行中的单个阶段（`-f stage=s3`） |
| `ci-debug.yml` | 仅 `workflow_dispatch`（`stage`、`boot_timeout`） | `debug-session`、`debug-<stage>-logs` | 需要在 runner 上开交互式 SSH 会话、某个阶段需要人眼时 |
| `release.yml` | 推送 `v*` tag | 发布资产 | 发布本项目自己的版本 |
| `upstream-watch.yml` | `schedule`（`0 16 * * *`）与 `workflow_dispatch`（`version`、`dry-run`、`base`、`resume`） | 以上游版本命名的发布，或一个 `[auto-release]` issue | 每日上游发布，或它的彩排 |

schedule 是 `0 16 * * *`：UTC 16:00，也就是北京零点。偏移写进 cron 里，没有 `timezone:`
字段，因为本仓库钉住的 actionlint 不保证认识这个较新的键。GitHub 的 `schedule` 触发是尽力
而为，实测延迟 3.5 到 4.8 小时，因此下游不依赖 job 实际开始的钟点。

可复用文件共十三个。`ci-resolve.yml`、`ci-fetch.yml`、`ci-assemble.yml` 与
`ci-verify.yml` 各管一个阶段。`ci-s1.yml` 到 `ci-s5.yml` 是五个阶段工作流。

其余四个是 `ci-upgrade-cross.yml`、`ci-report.yml` 与 `ci-upgrade-gates.yml`。
`release-publish.yml` 是两条发布线共用的发布器。

- **并发。** 只有 `ci.yml` 与 `ci-debug.yml` 声明 concurrency 组，因为被调用的工作流运行在
  调用者的 run 里，嵌套的组会让这次调用静默消失。
- 组名是 `ci-<workflow>-<lane>-<ref>`，lane 取自 `workflow_dispatch`；`cancel-in-progress`
  只对自动 lane 为真，因此两次手动运行会排队而不是互相取消。
- `ci-debug.yml` 两个 lane 都取消，因为第二次会话应当替换第一次而不是排在它后面等。
- **超时。** 每个跑步骤的 job 都带 `timeout-minutes`：resolve 10、fetch 20、assemble 35、
  verify 30、S1 30、S2 40、S3 45、S4 与 S5 75、report 20。
- debug job 是 290 分钟，另有 150 分钟的 keep-alive。
- **钉版本。** 每个第三方 action 都钉在 40 字符的 commit sha 上，绝不钉浮动 tag：用 runner
  凭据运行的就是被审阅过的代码。
- `.github/actions/` 下的六个复合 action 承载重复的步骤组。

## 五个阶段

每个阶段是一个可复用工作流，它的 job 标签在图里和 job 列表里是同一个字符串。

| 阶段 | 标签 | 证明什么 | 失败时什么坏掉 |
|---|---|---|---|
| S1 | `S1 Probe - Kernel Mounts Btrfs` | 官方内核在我们的 initramfs 里加载官方 btrfs 模块闭包并挂载 btrfs | 之后的阶段都不能在 `switch_root` 前依赖 btrfs |
| S2 | `S2 Image - Four Partitions` | 四分区几何、ESP 内容与 GPT PARTNAME，从客户机内部读回 | 什么都装不了：安装器写下的布局是错的 |
| S3 | `S3 Boot - Layered Root` | 启动 initramfs 组装 overlay 根并到达 `switch_root`，连续两次 | 没有槽位能启动，镜像不可安装 |
| S4 | `S4 Slots - A/B State Machine` | 经过四次启动验证提交、放弃与回滚，含健康检查 | A/B 切换未被证明：升级可能卡在坏槽位上 |
| S5 | `S5 Upgrade - Upgrade and Reclaim` | payload 升级、降级启动与回收，四次启动 | 升级未被证明，包括可写分区挂掉的情形 |

每个阶段打印一行固定判据，`S1-RESULT=` 到 `S5-RESULT=`。上表的标签是固定文本，遵循规则 4；
它背后的 token 是冻结的，改名永远不许碰它。

## 跨版本阶段

有一个阶段回答另一个问题：不是"这个版本是否健全"，而是"这个版本能否装在上一版之上"。
它只在 tag 线上运行；上游线不跑它。

| 阶段 | job 标签 | 证明什么 |
|---|---|---|
| cross | `Cross-Upgrade` | 用上一个正式版本构建的镜像，被本版本的 payload 升级后，能启动、能提交，且携带的正是 payload 发布的那个内核与 initrd |

它很贵——要用另一个上游版本再构建一次镜像——所以 PR 链从不跑它。选择器
（`matrix-select.sh`）指定上一个版本。当它找不到时（`gaps>0`），阶段报告
`cross-upgrade=skipped`，运行不算绿：被跳过的证明不是通过的证明。

`scripts/ci/cross-upgrade.sh assert --out <dir>` 能从五个文件重新评判一次运行，无需重跑
QEMU。这五个文件是之前、之中、之后的 status 行，ESP 摘要，payload 摘要与串口日志。

## 升级闸门

一次发布要证明两种不同的升级。`ci-upgrade-gates.yml` 同时提供两者，调用方指定模式而不是
文件：

| 模式 | 证明什么 | 上限 |
|---|---|---|
| `cross` | 版本 N 能装在版本 N-1 之上，无论两者各钉了哪个 base | 评判 job 35 分钟 |
| `same-base` | 版本 N 能装在版本 N-1 之上且 base 与内核相同：用上一版自己发布的镜像、本次运行的 payload | 25 分钟 |

same-base 模式把 tag 与摘要绑在一起，因为两个版本可能发布同名资产。
`scripts/ci/release-same-base.sh` 就是这份契约：

- `select` 回答哪个 tag、哪个资产、哪个摘要。
- `fetch` 拒绝哈希不等于该 tag 自己的 `SHA256SUMS` 所列摘要的字节。
- `judge` 仅凭文件评判四条标准。

闸门在哪里运行：

| 调用方 | job | 发布闸门 |
|---|---|---|
| `release.yml`（`v*` tag） | `build`、`cross`、`same-base`、`publish` | `publish: needs: [build, cross, same-base]` |
| `upstream-watch.yml`（每日 watch） | `detect`、`bump`、`build`、`locks`、`merge`、`publish` | `publish: needs: [detect, merge]` |

被跳过的闸门不是通过的闸门。缺少上一版、缺少 QEMU、缺少 `SHA256SUMS`，或阶段留下了
`skip` 文件，两种模式都失败。

无法识别的 `mode` 在 `guard` job 里失败，而不是两个闸门都跳过。仅有
`needs: [build, cross]` 只是发布要证明的一半：它证明不了升级提示所声称的 same-base 结论。
所以发布闸门同时点名两种模式。

## 产物

| 产物 | 由谁产生 | 内容 | 用途 |
|---|---|---|---|
| `image-install` | S3 | `n5105-ab-<upstream>-install.img.gz` | 写到磁盘的镜像；发布重发这些同样的字节 |
| `image-install-wan-ssh` | S3 的变体 job | 同一镜像加上 WAN SSH 规则 | 便利镜像，见 [install.zh-CN.md](install.zh-CN.md) |
| `image-probe` | S2 | 同一几何，探测用 initramfs | **绝不写到磁盘**：它找 `/dev/vda`，在真机上直接关机 |
| `payload-upgrade` | assemble | `payload.tar`、其 manifest 与检查日志 | `ab-upgrade` 消费的东西 |
| `upstream-files` | fetch | 上游 rootfs、内核与 btrfs 模块 | 输入；保留下来以便无网审计一次运行 |
| `evidence-s1` … `evidence-s5`、`evidence-cross` | 各阶段 | 串口日志、initramfs、清单、fixture 转储 | 阶段被评判所依据的结构化证据 |
| `logs-<stage>` | 各阶段 | 阶段的日志文件与诊断摘要 | 阶段失败时唯一要翻的地方 |

发布文件的命名是四段：板子、产品线、上游 base、角色。例如
`n5105-ab-<upstream>-install.img.gz`。升级包是 `n5105-ab-<upstream>-upgrade.tar`。

本项目自己的发布计数不在名字里，它所在的 GitHub release 才带着它。`release-notes.md` 写在
资产旁边并成为 release 正文。所以一次发布是三个资产、四个文件。

## 阅读一次运行的页面

- 每个阶段 job 末尾有一张**阶段摘要**：一张表，列为 `stage`、`verdict`、`key line`、
  `artifact and sha256`、`next command`。该阶段的一切都在这里；日志只用于细节。
- **report** job 渲染跨流水线的一张表：`stage`、`verdict`、`duration`、`artifact`，后接各
  判据行。时长取自 Actions API，因此是真实的 job 墙钟时间。
- 失败的运行会在第一行重复要点：哪个阶段失败，以及显示原因的命令。

处理失败：先读报告第一行，打开该阶段的摘要块。再按它的 `next command` 走，那里要么是
`gh run view <run> --log-failed`，要么是本地复现命令。最后才去翻 `logs-<stage>`。

## 本地复现一个阶段

阶段脚本读环境变量，把临时文件写在 `$CI_TMP_ROOT` 下。`GITHUB_OUTPUT` 与
`GITHUB_STEP_SUMMARY` 可选。`CI_OUTPUT_ENV` 把阶段输出变成下一个阶段加载的 `KEY=VALUE`
文件。全程不需要 GitHub 客户端。

```sh
export CI_TMP_ROOT=/tmp/ci
mkdir -p "$CI_TMP_ROOT"

# 解析上游版本，再取它的文件
CI_OUTPUT_ENV="$CI_TMP_ROOT/resolve.env" bash scripts/ci/resolve.sh
CI_RESOLVE_ENV="$CI_TMP_ROOT/resolve.env" bash scripts/ci/fetch.sh

# 组装 payload；四个输入刻意没有默认值
CI_PLATFORM_VERSION="$(tr -d '[:space:]' < VERSION)" \
  CI_INITRAMFS="$(bash scripts/ci/initramfs.sh)" \
  CI_PLATFORM_RUNTIME_DIR="$(bash scripts/ci/platform-runtime.sh)" \
  CI_BOOT_SRC="$(bash scripts/ci/esp-prepare.sh)" \
  bash scripts/ci/assemble.sh
```

`resolve.sh` 需要网络：它下载该版本的 `sha256sums` 与软件包清单。它的缓存键覆盖解析出的
摘要、工具版本，以及每个 `scripts/ci/*.sh` 与 `.github/workflows/*.yml` 的内容。因此这些
文件一改，键就变。

`CI_UPSTREAM_VERSION` 指定另一个版本，`latest` 解析镜像站上的最新版本，都不给时由 pin
决定。

QEMU 阶段读 `CI_QEMU_MODE`（`kernel`、`uefi`、`uefi-disk`）。它还读 `CI_QEMU_TIMEOUT` 与
`CI_JUDGE_PREFIX`，以及前面阶段写下的文件：

```sh
CI_QEMU_MODE=uefi-disk CI_QEMU_TIMEOUT=900 CI_JUDGE_PREFIX=S3-RESULT \
  CI_KERNEL="$CI_TMP_ROOT/fetch/upstream/kernel.bin" \
  CI_INITRAMFS="$CI_TMP_ROOT/initramfs/initramfs.cpio.gz" \
  CI_QEMU_DISK="$CI_TMP_ROOT/disk/n5105-ab-image.img" \
  bash scripts/ci/qemu-smoke.sh
```

改为在 runner 上跑单个阶段：

```sh
gh workflow run ci.yml --ref main -f stage=s3 -f upstream_version=25.12.2
```

`stage` 接受 `all`、`fetch`、`assemble`、`s1`、`s2`、`s3`、`s4`、`s5` 与 `verify`；其余 job
在图中保持 skipped，因此该阶段由与完整运行相同的脚本、相同的输入来评判。

| 部分 | Linux 主机 | macOS | 原因 |
|---|---|---|---|
| `resolve.sh`、`fetch.sh` | 可用 | 可用 | shell 与 `curl`；缺 `sha256sum` 时 `lib.sh` 回退到 `shasum -a 256` |
| `assemble.sh`、`verify.sh` | 可用 | 不可 | 需要 initramfs、暂存的 btrfs 工具与 ESP 树；缺 linter 按设计就是阶段失败 |
| S1 到 S5、`disk.sh`、`qemu-smoke.sh` | 可用 | 不可 | 需要 `qemu-system-x86_64`、`losetup`、`sfdisk`、`mkfs.vfat`、`mkfs.btrfs`、`chattr`、`blkid`、`timeout` |
| `python3 scripts/check_design.py all`、`./tests/run.sh` | 可用 | 可用 | 与 `verify.sh` 相同的检查，只是不含 linter |

常见失败：

| 现象 | 通常意味着 | 怎么做 |
|---|---|---|
| `WARNING: ignoring invalid upstream pin …` | pin 行不是 `X.Y.Z`，于是用了内置默认值 | 在 `.github/upstream-pin.conf` 里只留一行 `UPSTREAM_VERSION=X.Y.Z` |
| `invalid upstream version: '25.13' does not match ^[0-9]+\.[0-9]+\.[0-9]+$` | 显式指定的版本不是正式发布 | 给一个正式 `X.Y.Z` 版本、传 `latest`，或不传以使用 pin |
| 临时文件跑到 `/tmp/ci` 而不是你的目录 | `CI_TMP_ROOT` 没有 export | 在第一个脚本前 `export CI_TMP_ROOT=/tmp/ci` |
| `no boot source at … and CI_REQUIRE_BOOTLOADER=1` | payload 阶段找不到可取其 GRUB 的 ESP 树 | 先跑 `bash scripts/ci/esp-prepare.sh`，或把 `CI_BOOT_SRC` 指向带 loader 的树 |
| `actionlint: fail` 与 `shellcheck: fail`，旁边是 `design: ok` | linter 不在 `PATH` 上；缺 linter 就是阶段失败 | 装好两者，或设 `CI_ACTIONLINT_BIN`；只查文档用 `python3 scripts/check_design.py all` |
| 真机在 GRUB 菜单关机，串口日志以 `S1-RESULT=fail reason=no-device-node` 结束 | 写盘用的是 `image-probe` | 写 `image-install` 或发布资产 |

构建 pin 之外的版本也可以：流水线在 `$CI_TMP_ROOT/locks/` 下派生自己的三份 lockfile 副本，
对其断言并在运行页告警。`CI_LOCK_STRICT=1` 恢复对每个版本的硬失败。

## 发布线

一次发布沿两条线之一离开本仓库。**tag 线**发布本项目自己的版本：推一个 `v0.0.9` tag，发布
就出现。**上游线**发布新的 ImmortalWrt base：每日 watch 发现新的正式上游版本，构建它、移动
pin、合并，并以裸上游版本号（`25.13.0`）发布。

| | tag 线 | 上游线 |
|---|---|---|
| 触发 | 推 `v*` tag（`release.yml`） | `schedule`（`0 16 * * *`），或 `upstream-watch.yml` 的 `workflow_dispatch` |
| tag 形状 | `v<X.Y.Z>`，预览版为 `v<X.Y.Z>-rc.<N>` | 裸 `<X.Y.Z>` |
| `VERSION` | tag 必须等于它 | 发布不改它；它仍携带镜像记录的平台版本 |
| 构建哪个上游 | `.github/upstream-pin.conf` 里的 pin | `detect` 刚发现的版本，作为 `upstream_version` 传入 |
| 发布标题 | `N5105 AB Firmware <tag>` | `ImmortalWrt N5105 AB Firmware <tag>` |
| 资产 | 安装镜像、便利镜像、payload、`SHA256SUMS` | 安装镜像、payload、`SHA256SUMS` |
| 失败落在哪 | tag 上的运行变红，不发布，tag 保留 | 一个标题为 `[auto-release] <version>`、带 `auto-release` 标签的 issue |

两条线都调用 `release-publish.yml`，它在创建任何东西之前先跑
`scripts/ci/release-preflight.sh`。两个调用方、一个实现，是两条线不漂移的原因。

预览版就是一次普通的发布，只是 tag 带预发布后缀 `v0.1.0-rc.1`。它的 `VERSION` 等于去掉
`v` 的同一个字符串。

后缀是它作为预览版的唯一标志：该次运行把它发布为 GitHub pre-release，因此 `latest` 仍指向
上一个正式版。读 `latest` 的更新器不会装到发布候选。

便利镜像与默认镜像只差一个渲染值 `NET_WAN_SSH`：WAN 侧防火墙是否多一条 `allow_ssh_wan`
规则（`22/tcp`）。内核、rootfs、平台层与 payload 两者逐字节相同。

`scripts/ci/release.sh` 在文件名后加 `-wan-ssh`，因此下载页绝不会用闭合版本的名字提供开放
版本。变体 job 设 `boots: false`：启动断言在发布的默认镜像上证明一次。

`dry-run: true` 是发布器的彩排开关：每个步骤都跑，字节被上传并校验，发布以**草稿**形式
创建。在上游线上彩排还会跳过合并与打 tag，因此它不能移动分支。

## 一个 tag 要证明什么

preflight 挂载镜像、证明其中的 initrd 是生产 initrd，并运行下面的检查——全部在
`gh release create` 之前；拒绝是非零退出，不是告警。

两种策略共有：

- `ab/image.json` 写着 `"kind": "boot"`——探测镜像被拒；
- 发布的 initrd 打印 `S3 boot init` 且不含 `S1-RESULT`；
- payload manifest 是 `ab-payload/1` 且带 `rootfs` 版本；
- payload tar 确实按记录的 sha256 携带每个成员；
- payload 带 `boot.tar`，其中有 `grub.cfg` 与 GRUB 核心：一个无法被升级的镜像不算发布。

`--tag-policy v` 另外断言四件事：

- tag 匹配 `^v[0-9]+\.[0-9]+\.[0-9]+$`；
- 平台版本等于去掉 `v` 的 tag；
- `ab/image.json` 记录同一平台版本；
- 其 `upstream_version` 等于 payload manifest 的 `rootfs`。

`--tag-policy bare` 另外断言四件事：

- tag 匹配 `^[0-9]+\.[0-9]+\.[0-9]+$`；
- 镜像的 `upstream_version` 等于 tag；
- manifest 的 `rootfs` 等于 tag；
- 随镜像发布的 `VERSION` 仍携带该平台版本。

上游线换掉 base，不动本项目的版本号。

每处不一致都以 `release-preflight: <reason>` 行一次报告。

## 每日上游 watch

`upstream-watch.yml` 是一张 run 图，因为用 `GITHUB_TOKEN` 推的 commit 或 tag 不会自己触发
工作流。

schedule 是 `0 16 * * *`：UTC 16:00，即北京零点。GitHub 的 `schedule` 触发是尽力而为，实测
延迟 3.5 到 4.8 小时，因此下游不依赖 job 实际开始的钟点。

| 结果 | 图 | 怎么读 |
|---|---|---|
| 有新发布 | `detect` -> `bump` -> `build` -> `locks` -> `merge` -> `publish` -> `audit` | 绿色运行，之后存在裸 `<X.Y.Z>` tag 与一次发布 |
| 没有新东西 | `detect` + `keepalive` | 绿色运行，其余 job 全 skipped，没有创建分支、tag 或发布 |
| 失败 | 任何 job 失败或被取消 | 红色运行，以及一个标题为 `[auto-release] <version>` 的 issue |

只有一种形状算安静的绿色运行：索引提供了正式发布，而 pin 已经指向它。一个坏掉的镜像站解析
不出任何正式发布时会让 `detect` 失败，而不是看起来安静；pin 比最新正式发布更新时同样如此。

各 job：

- `detect` 找最新正式发布并与 pin 比较。
- `keepalive` 写下下面说的每月一行。
- `bump` 只在 `auto/upstream-<version>` 上改 `.github/upstream-pin.conf` 并开或更新 PR。
- `build` 以新版本调用 `ci.yml`。
- `locks` 派生三份 lockfile 并断言。
- `merge` 守住 diff（恰好四个文件）、squash 合并并推一个带注释的裸 tag。
- `publish` 以 `tag-policy: bare` 调用 `release-publish.yml`。
- `audit` 写审计日志里的 `upstream` 与 `release` 行。

三个问题对应的命令：

```sh
gh run list --workflow upstream-watch.yml --limit 5
gh run view <run-id> --json jobs --jq '.jobs[] | "\(.name): \(.conclusion)"'
gh issue list --label auto-release --state open
```

安静的日子也回答"watch 还活着吗"。GitHub 会在公开仓库的定时工作流 60 天无仓库活动后将其
停用，因此 keepalive 就是让 schedule 保持开启的那点活动：

- 它往 `.github/keepalive.log` 追加一行：
  `<UTC ISO8601> keepalive last_commit=<sha> days_since=<n>`。
- 基线是默认分支的最后一次 commit，因此任何推送都已经算作活动。
- 只有基线至少 25 天（`CI_KEEPALIVE_INTERVAL_DAYS`）时才写一行；否则脚本回答
  `action=skipped` 且什么都不写。
- job 提交这一行并推送到默认分支，分支被移动时有次数上限的 rebase 重试。
- 同一天或对同一个 commit 重跑是 no-op。

这是仓库内最强的信号，但它不是保证。GitHub 对 bot commit 如何计入 60 天规则没有官方定义，
而 `main` 上的分支保护会拒绝这次推送、让运行变红。外部 cron 才能让 schedule 确定，
keepalive 只让它更可能。

前提条件：仓库是公开的（否则 60 天无活动后 schedule 会被停用）；默认 `GITHUB_TOKEN` 可写；
`main` 不要求 token 创建的 PR 无法满足的状态检查，因为那样的推送不会触发工作流。

`keepalive` 与两个 `audit` job 直接推 `main`，因此要求 PR 的分支保护规则必须给它们显式
bypass。另一种做法是把这两个 job 改成开 PR，代价是记录不再即时。

三者可能同时运行。各自对一次被拒的推送做三次 rebase 重试，彼此不协调；写的也不是同一
行，因此最坏结果是一条 job 变红，而不是数据丢失。

成本：安静的一次运行只是一个耗时数秒的 `detect` job 加上 `keepalive` job，后者约每月多一个
commit。有新发布则要付五阶段构建（实测端到端 18 分钟）加 `locks`、`merge`、`publish` 与
`audit`。watch 两个升级闸门都不跑，因此绿色 watch 只证明构建与合并，不证明该发布能装在上
一版之上。

## 自动化审计日志

`.github/automation-log.md` 记录自动化做过什么，形式是人不用打开运行页就能读。它是 tracked
文件，表头固定：`| time | event | detail | result | link |`。

四种事件：

- `upstream`——每日 watch 发现了新的上游正式发布并构建了它。
- `release`——那次构建被发布成 release。
- `platform`——推送到 `main` 的提交改了 `platform/`、`initramfs/`、`VERSION` 或上游 pin。
- `failure`——自动发布的某个阶段失败。脚本支持这个事件，但目前没有 workflow 调用它，这一
  行保留给 auto-release 失败接线。

谁写它：

- `scripts/ci/automation-log.sh` 独占所有写入：表头只在建文件时写一次，行只追加。
- cell 里的 `|` 转义成 `\|`，多行 cell 折叠成一行，因为列数悄悄漂移的表格比没有表格更糟。
- 在 `upstream-watch.yml` 里，`audit` job 在 `publish` 返回后写 `upstream` 行，只有不是彩排
  时才写 `release` 行。彩排的行写 `result=rehearsed`，且不写 release 行。
- 在 `ci.yml` 里，`audit` job 在推送 `main` 命中那四条路径时写 `platform` 行，否则什么都不
  写。
- `platform` 行读的是两提交检出下的 `HEAD^1..HEAD`：一次 push 含多个提交时只判断最后
  一个提交，因此漏记而非误记。这是刻意的设计。
- 写入失败不改变构建的结论：`audit` job 自己变红，因此停止记录的日志会显形，而不是安静地
  通过。

本地补写一行：

```sh
bash scripts/ci/automation-log.sh append --event platform \
  --sha "$(git rev-parse --short HEAD)" --subject "$(git log -1 --format=%s)" \
  --link https://github.com/example/repo/actions/runs/42
```

两个记录文件、两个脚本：`keepalive.log` 每月一行，回答"schedule 还活着"；
`automation-log.md` 是读者解析的表格。两者都不由人手写，也不由别的脚本写。

## 调度状态

`ci.yml` 有一个 `schedule-state` job。它向 API 询问 `upstream-watch.yml` 的状态，在 schedule
关闭时失败。被停用的 watch 是静默的自动发布中断，没有任何构建阶段会注意到。

```sh
gh api repos/{owner}/{repo}/actions/workflows/upstream-watch.yml --jq .state
bash scripts/ci/schedule-health.sh    # 同一个问题，本地版本
```

`schedule-health.sh` 用退出码回答：

- `0`：`state=active`，schedule 是开着的。
- `1`：被停用；运行变红，步骤摘要里给出 `gh workflow enable` 命令。
- `2`：`gh`、它的凭据或 API 什么也没答出来。

这个 job 只在 `push`、`pull_request` 与 `workflow_dispatch` 上跑。被调用的运行看到的是调用者
的事件名，因此这里的 `schedule` 只可能意味着"upstream-watch 调了我"；评判调用者的 schedule
是调用者的事。

`ci.yml` 自己没有 `schedule` 触发器，因此这三个事件就是全部白名单。

## PR 支持与必需检查

`ci.yml` 对 `main` 的 `pull_request` 运行。一次 PR 得到与推送相同的图——五个阶段、静态检查与
report——外加 `schedule-state`，它回答每日 watch 是否还开着。

- **只读 token。** `ci.yml` 声明 `permissions: contents: read`，因此一次 PR 运行只读。唯一
  例外是 `audit` job，它申请 `contents: write`，且只在推送到 `main` 时运行。
- **caller 的 permissions 是上限。** 被调的 job 不能申请超过调用者授予的权限。越权会让整次运行
  在启动阶段失败，既没有 job 列表，也没有日志。
- **本仓库如何满足。** `release.yml` 与 `upstream-watch.yml` 调用 `ci.yml` 时同时授予
  `contents: write` 与 `actions: read`，因为 `audit` 与 `report` job 分别需要这两项。
  `scripts/check_design.py reusable-permissions` 对放不下的调用直接失败。
- **fork PR。** 来自 fork 的 PR 拿到只读的 `GITHUB_TOKEN`，且没有仓库 secret。这张图两样都
  不需要：它从公开镜像站下载，只写在运行内部。
- **不引入 `pull_request_target`。** 那个事件在基仓库里带着写 token 与 secret 运行，在那里
  checkout fork 的代码等于把钥匙交给 fork。
- 本仓库不使用它；要 checkout PR 代码的工作流留在 `pull_request` 上。

本仓库目前不要求任何状态检查。若要加分支保护，点名一次运行真会产出的检查：

```sh
gh api repos/{owner}/{repo}/branches/main/protection/required_status_checks --jq '.contexts[]'
gh api repos/{owner}/{repo}/commits/main/check-runs \
  --jq '.check_runs[] | "\(.name): \(.conclusion)"'
gh pr checks <number>
```

- `Report` 是一次运行的唯一判据：它 needs 每个阶段，任一阶段失败它就失败，因此要求它就覆盖
  了整条流水线。
- `Static Checks` 是唯一值得单独要求的 job，这样 lint 失败会被点名而不是被概括。
- `Schedule State` 在每日 watch 被停用时失败，这是仓库级事实。要求它会让被停用的 watch 在每
  个 PR 上可见，包括只改文档的 PR。这是一个刻意的选择，不是默认值。

两个小事实在设置时会碰到：

- `main` 没有保护时第一条命令返回 404。那是"没有必需检查"的答案，不是错误。
- `gh pr checks <number>` 列出这次 PR 上真正跑过的检查，是改名后确认某个必需名字仍然存在
  的快捷方式。

## 交互式调试

`ci-debug.yml` 在 runner 上开一个交互式 shell，用于某个阶段卡住、日志又不够的时候。它不是
闸门：绿色运行只说明会话开起来了，不说明某个槽位提交了。

```sh
gh workflow run ci-debug.yml --ref main -f stage=s4 -f boot_timeout=1200
gh run list --workflow ci-debug.yml --limit 1
```

| `stage` | shell 打开前先跑什么 |
|---|---|
| `none` | 只跑工具；最便宜的会话 |
| `build-disk` | resolve、fetch、kmods、esp-prepare、platform-runtime、initramfs、disk、GRUB 预检 |
| `s4` | `build-disk`、网络 fixture 与第一次启动（新镜像，提交槽位 a） |
| `s5` | `build-disk`、升级 payload、s5 fixture 与第一次启动 |

`boot_timeout` 就是那次首启的 `CI_QEMU_TIMEOUT`（默认 1200 秒）。从 `main` 运行：
`workflow_dispatch` 运行的是所选 ref 上的工作流文件，因此在分支上运行时执行的是该分支版本的
每一步。

会话步骤用 `owenthereal/action-upterm` 并设 `detached: true`。它把连接行发布到运行摘要页与
`debug-session` 产物：

```sh
ssh session:<token>@uptermd.upterm.dev
ssh -i ~/.ssh/id_ed25519 session:<token>@uptermd.upterm.dev   # 非默认密钥
```

`limit-access-to-actor: true` 意味着只有触发该次运行的用户在 GitHub 上登记的 SSH 公钥能连；
该账号没有公钥时谁都连不上。

这个字符串只是定位会话，私钥才是凭据：把它、`join-command` 与 `ssh-config` 当作同一件凭证，
任何一条都不要外贴。

`full-access: true` 让 shell 真正可用，而它只授予一个随 job 一起销毁的 VM。

边界：会话步骤上限 10 分钟，keep-alive 步骤 150 分钟（140 分钟时自停），job 240 分钟，远在
GitHub 的 6 小时硬上限之内。时长来自步骤与 job 上的 `timeout-minutes`，从不来自 shell
字面量。`scripts/check_design.py debug-ssh` 断言这一安排。

SSH 连接断开不会结束会话——在 shell 里 `exit`，或取消运行，才会。运行摘要、`debug-session`
产物（保留一天）与 `debug-<stage>-logs`（保留七天）是残留；日志不再需要后删除该次运行。

## CI 文本契约

CI 对人说的每句话都是契约，因为运行页只被读一次，而且是在压力下。七条规则，由
`tests/modules/ci/test_ci_text_conventions.sh` 断言：

1. **界面上只用英文。** `.github/workflows/*.yml`、`.github/actions/*/action.yml` 与
   `scripts/ci/*.sh` 里每个非注释行都是 ASCII。中文只出现在 `docs/*.zh-CN.md`。
2. **标签不是句子。** 结尾没有句号或感叹号，首尾没有空格。
   - 工作流与 job 标签用 Title Case：每个槽都以大写词开头并以大写词结尾，只有
     `a an the and of for to in on by or` 这些短冠词、介词与连词在槽内保持小写。
   - 步骤标签与所有句子保持句首大写（sentence case）。
3. **长度上限。** 工作流或 job 名 40 字符，步骤名 60 字符，issue、PR 或发布标题 80 字符。
4. **每一层一种语法槽。** 入口是 `Firmware CI - <role>`；可复用文件是 `S<n> <semantic>` 或
   简短角色短语。
   - 阶段 job 是 `S<n> <semantic> - <what it proves>`；步骤是 `<Verb phrase>` 或
     `<Marker> - <claim>`；分隔符恰好是 ` - `。
   - 工作流与 job 的每个槽都填 Title Case，而步骤保留动词首字母大写、其余仍是 sentence
     case。
   - 步骤不带阶段号；不决定阶段成败的步骤以 ` - advisory` 结尾。
5. **固定摘要表。** 七个表头，不能有第八个：
   - `stage | verdict | key line | artifact and sha256 | next command`
   - `stage | verdict | duration | artifact`
   - `field | value`
   - `job | result`
   - `artifact | size | sha256`
   - `file | written this run`
   - `time | event | detail | result | link`
6. **固定标题模板。** `[auto-release] <version>`、`chore(ci): pin upstream <version>`、
   `# Upstream <version> (pin <old> -> <new>)`，以及由 `tag-policy` 派生的两个发布标题。
7. **结构不是文本。** 改文字不得改运行。`tests/fixtures/ci-structure-fingerprint.txt` 为每个
   结构 token 保存一行排序结果，因此一次措辞批次让它逐字节不变；移动的键会自己显形。

命名简述：分隔符只有一个 ` - `；阶段是 `S<n> <semantic>`。每个工作流与 job 标签都是
Title Case，步骤不带阶段号。不决定阶段成败的步骤以 ` - advisory` 结尾。

## 限制

- 被跳过的阶段或闸门从不被报告为通过。
- 流水线不编译内核：它消费官方 rootfs、内核与 btrfs 模块，因此上游构建内部的缺陷超出它的
  能力范围。
- 自动线无法用自己的运行来证明自己：被停用的 schedule 不产生任何运行，所以必须从外部用
  `gh api repos/:owner/:repo/actions/workflows/<id> --jq .state` 检查。
- keepalive 是仓库内最强的信号，不是证明：只有外部 cron 才能确定一个定时工作流保持启用。
- 本仓库的发布不可撤销：tag 不移动，因此坏发布只能被后继版本取代，不能被重写。

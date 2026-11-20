# CI

**中文** | [English](ci.md)

流水线在 GitHub Actions 上构建、启动并评判固件，而它做出的每个决定都可以在没有 GitHub 的
Linux 机器上复现。本页是地图：跑哪个文件、每个阶段证明什么、一次发布要证明什么，以及 CI
允许对人说什么话。

阶段脚本本身见 [`../scripts/ci/README.md`](../scripts/ci/README.md)；驱动真机的那套见
[device-matrix.md](device-matrix.md)。

## 工作流文件与入口

`.github/workflows/` 下十六个文件。四个能发起运行，其余十二个只声明 `workflow_call`，
因此不能。

| 工作流文件 | 触发 | 产物 | 何时运行 |
|---|---|---|---|
| `ci.yml` | 推送或对 `main` 的 PR、`workflow_dispatch`（`stage`、`upstream_version`）、`workflow_call` | 自身没有：它调用各阶段 | 日常验证，或失败运行中的单个阶段（`-f stage=s3`） |
| `ci-debug.yml` | 仅 `workflow_dispatch`（`stage`、`boot_timeout`） | `debug-session`、`debug-<stage>-logs` | 需要在 runner 上开交互式 SSH 会话、某个阶段需要人眼时 |
| `release.yml` | 推送 `v*` tag | 发布资产 | 发布本项目自己的版本 |
| `upstream-watch.yml` | `schedule`（`0 0 * * *`）与 `workflow_dispatch`（`version`、`dry-run`、`base`、`resume`） | 以上游版本命名的发布，或一个 `[auto-release]` issue | 每日上游发布，或它的彩排 |

十二个可复用文件是 `ci-resolve.yml`、`ci-fetch.yml`、`ci-assemble.yml`、`ci-verify.yml`、
`ci-s1.yml` 到 `ci-s5.yml`、`ci-upgrade-cross.yml`、`ci-report.yml`、`ci-upgrade-gates.yml`
与 `release-publish.yml`。

- **并发。** 只有 `ci.yml` 与 `ci-debug.yml` 声明 concurrency 组，因为被调用的工作流运行在
  调用者的 run 里，嵌套的组会让这次调用静默消失。组名是 `ci-<workflow>-<lane>-<ref>`，
  lane 取自 `workflow_dispatch`，`cancel-in-progress` 只对自动 lane 为真：两次手动运行会
  排队而不是互相取消。`ci-debug.yml` 两个 lane 都取消，因为第二次会话应当替换第一次而不是
  排在它后面等。
- **超时。** 每个跑步骤的 job 都带 `timeout-minutes`：resolve 10、fetch 20、assemble 35、
  verify 30、S1 30、S2 40、S3 45、S4 与 S5 75、report 20，debug job 290，另有 150 分钟的
  keep-alive。
- **钉版本。** 每个第三方 action 都钉在 40 字符的 commit sha 上，绝不钉浮动 tag：用 runner
  凭据运行的就是被审阅过的代码。`.github/actions/` 下的六个复合 action 承载重复的步骤组。

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
（`matrix-select.sh`）指定上一个版本；当它找不到时（`gaps>0`），阶段报告
`cross-upgrade=skipped`，运行不算绿：被跳过的证明不是通过的证明。
`scripts/ci/cross-upgrade.sh assert --out <dir>` 能从五个文件重新评判一次运行——之前、
之中、之后的 status 行，ESP 摘要，payload 摘要与串口日志——无需重跑 QEMU。

## 升级闸门

一次发布要证明两种不同的升级。`ci-upgrade-gates.yml` 同时提供两者，调用方指定模式而不是
文件：

| 模式 | 证明什么 | 上限 |
|---|---|---|
| `cross` | 版本 N 能装在版本 N-1 之上，无论两者各钉了哪个 base | 评判 job 35 分钟 |
| `same-base` | 版本 N 能装在版本 N-1 之上且 base 与内核相同：用上一版自己发布的镜像、本次运行的 payload | 25 分钟 |

same-base 模式把 tag 与摘要绑在一起，因为两个版本可能发布同名资产。
`scripts/ci/release-same-base.sh` 就是这份契约：`select` 回答哪个 tag、哪个资产、哪个摘要；
`fetch` 拒绝哈希不等于该 tag 自己的 `SHA256SUMS` 所列摘要的字节；`judge` 仅凭文件评判四条
标准。

闸门在哪里运行：

| 调用方 | job | 发布闸门 |
|---|---|---|
| `release.yml`（`v*` tag） | `build`、`cross`、`same-base`、`publish` | `publish: needs: [build, cross, same-base]` |
| `upstream-watch.yml`（每日 watch） | `detect`、`bump`、`build`、`locks`、`merge`、`publish` | `publish: needs: [detect, merge]` |

被跳过的闸门不是通过的闸门。两种模式在缺少上一版、缺少 QEMU、缺少 `SHA256SUMS` 或阶段留下
`skip` 文件时都失败，无法识别的 `mode` 在 `guard` job 里失败而不是两个闸门都跳过。仅有
`needs: [build, cross]` 只是发布要证明的一半：它证明不了升级提示所声称的 same-base 结论，
所以发布闸门同时点名两种模式。

## 产物

| 产物 | 由谁产生 | 内容 | 用途 |
|---|---|---|---|
| `image-install` | S3 | `n5105-ab-<upstream>-install.img.gz` | 写到磁盘的镜像；发布重发这些同样的字节 |
| `image-install-wan-ssh` | S3 的变体 job | 同一镜像加上 WAN SSH 规则 | 便利镜像，见 [install.md](install.md) |
| `image-probe` | S2 | 同一几何，探测用 initramfs | **绝不写到磁盘**：它找 `/dev/vda`，在真机上直接关机 |
| `payload-upgrade` | assemble | `payload.tar`、其 manifest 与检查日志 | `ab-upgrade` 消费的东西 |
| `upstream-files` | fetch | 上游 rootfs、内核与 btrfs 模块 | 输入；保留下来以便无网审计一次运行 |
| `evidence-s1` … `evidence-s5`、`evidence-cross` | 各阶段 | 串口日志、initramfs、清单、fixture 转储 | 阶段被评判所依据的结构化证据 |
| `logs-<stage>` | 各阶段 | 阶段的日志文件与诊断摘要 | 阶段失败时唯一要翻的地方 |

发布文件名为 `n5105-ab-<upstream>-install.img.gz` 或 `n5105-ab-<upstream>-upgrade.tar`：
板子、产品线、上游 base、角色。本项目自己的发布计数不在名字里——它所在的 GitHub release
已经带着它。`release-notes.md` 写在资产旁边并成为 release 正文，所以一次发布是三个资产、
四个文件。

## 阅读一次运行的页面

- 每个阶段 job 末尾有一张**阶段摘要**：一张表，列为 `stage`、`verdict`、`key line`、
  `artifact and sha256`、`next command`。该阶段的一切都在这里；日志只用于细节。
- **report** job 渲染跨流水线的一张表：`stage`、`verdict`、`duration`、`artifact`，后接各
  判据行。时长取自 Actions API，因此是真实的 job 墙钟时间。
- 失败的运行会在第一行重复要点：哪个阶段失败，以及显示原因的命令。

处理失败：先读报告第一行，打开该阶段的摘要块，按它的 `next command`（`gh run view <run>
--log-failed` 或本地复现），最后才去翻 `logs-<stage>`。

## 本地复现一个阶段

阶段脚本读环境变量，把临时文件写在 `$CI_TMP_ROOT` 下。`GITHUB_OUTPUT` 与
`GITHUB_STEP_SUMMARY` 可选，`CI_OUTPUT_ENV` 把阶段输出变成下一个阶段加载的 `KEY=VALUE`
文件，全程不需要 GitHub 客户端。

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
摘要、工具版本以及每个 `scripts/ci/*.sh` 与 `.github/workflows/*.yml` 的内容，因此这些一改
键就变。`CI_UPSTREAM_VERSION` 指定另一个版本，`latest` 解析镜像站上的最新版本，都不给时由
pin 决定。

QEMU 阶段读 `CI_QEMU_MODE`（`kernel`、`uefi`、`uefi-disk`）、`CI_QEMU_TIMEOUT`、
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
| 触发 | 推 `v*` tag（`release.yml`） | `schedule`（`0 0 * * *`），或 `upstream-watch.yml` 的 `workflow_dispatch` |
| tag 形状 | `v<X.Y.Z>`，预览版为 `v<X.Y.Z>-rc.<N>` | 裸 `<X.Y.Z>` |
| `VERSION` | tag 必须等于它 | 发布不改它；它仍携带镜像记录的平台版本 |
| 构建哪个上游 | `.github/upstream-pin.conf` 里的 pin | `detect` 刚发现的版本，作为 `upstream_version` 传入 |
| 发布标题 | `N5105 AB Firmware <tag>` | `ImmortalWrt N5105 AB Firmware <tag>` |
| 资产 | 安装镜像、便利镜像、payload、`SHA256SUMS` | 安装镜像、payload、`SHA256SUMS` |
| 失败落在哪 | tag 上的运行变红，不发布，tag 保留 | 一个标题为 `[auto-release] <version>`、带 `auto-release` 标签的 issue |

两条线都调用 `release-publish.yml`，它在创建任何东西之前先跑
`scripts/ci/release-preflight.sh`。两个调用方、一个实现，是两条线不漂移的原因。

预览版就是一次普通的发布，只是 tag 带预发布后缀 `v0.1.0-rc.1`，且 `VERSION` 等于去掉 `v`
的同一个字符串。后缀是它作为预览版的唯一标志：该次运行把它发布为 GitHub pre-release，
因此 `latest` 仍指向上一个正式版，读 `latest` 的更新器不会装到发布候选。

便利镜像与默认镜像只差一个渲染值 `NET_WAN_SSH`：WAN 侧防火墙是否多一条 `allow_ssh_wan`
规则（`22/tcp`）。内核、rootfs、平台层与 payload 两者逐字节相同。`scripts/ci/release.sh`
在文件名后加 `-wan-ssh`，因此下载页绝不会用闭合版本的名字提供开放版本。变体 job 设
`boots: false`：启动断言在发布的默认镜像上证明一次。

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

`--tag-policy v` 另外断言 tag 匹配 `^v[0-9]+\.[0-9]+\.[0-9]+$`、平台版本等于去掉 `v` 的
tag、`ab/image.json` 记录同一平台版本、其 `upstream_version` 等于 payload manifest 的
`rootfs`。

`--tag-policy bare` 另外断言 tag 匹配 `^[0-9]+\.[0-9]+\.[0-9]+$`、镜像的
`upstream_version` 等于 tag、manifest 的 `rootfs` 等于 tag、随镜像发布的 `VERSION` 仍携带
该平台版本。上游线换掉 base，不动本项目的版本号。

每处不一致都以 `release-preflight: <reason>` 行一次报告。

## 每日上游 watch

`upstream-watch.yml` 是一张 run 图，因为用 `GITHUB_TOKEN` 推的 commit 或 tag 不会自己触发
工作流。schedule 是 UTC 零点；GitHub 的 `schedule` 触发是尽力而为，实测延迟 3.5 到 4.8 小时，
因此下游不依赖 job 实际开始的钟点。

| 结果 | 图 | 怎么读 |
|---|---|---|
| 有新发布 | `detect` -> `bump` -> `build` -> `locks` -> `merge` -> `publish` | 绿色运行，之后存在裸 `<X.Y.Z>` tag 与一次发布 |
| 没有新东西 | 只有 `detect` | 绿色运行，其余 job 全 skipped，没有创建分支、tag 或发布 |
| 失败 | 任何 job 失败或被取消 | 红色运行，以及一个标题为 `[auto-release] <version>` 的 issue |

只有一种形状算安静的绿色运行：索引提供了正式发布，而 pin 已经指向它。一个坏掉的镜像站解析
不出任何正式发布时会让 `detect` 失败，而不是看起来安静；pin 比最新正式发布更新时同样如此。

各 job：`detect` 找最新正式发布并与 pin 比较；`bump` 只在 `auto/upstream-<version>` 上改
`.github/upstream-pin.conf` 并开或更新 PR；`build` 以新版本调用 `ci.yml`；`locks` 派生三份
lockfile 并断言；`merge` 守住 diff（恰好四个文件）、squash 合并并推一个带注释的裸 tag；
`publish` 以 `tag-policy: bare` 调用 `release-publish.yml`。

三个问题对应的命令：

```sh
gh run list --workflow upstream-watch.yml --limit 5
gh run view <run-id> --json jobs --jq '.jobs[] | "\(.name): \(.conclusion)"'
gh issue list --label auto-release --state open
```

安静的日子也回答"watch 还活着吗"：50 天没有活动时 `heartbeat` job 会推一个
`heartbeat-YYYYMM` tag，它无法触发发布。其前提——推 tag 算 GitHub 60 天规则里的"仓库活动"
——未经证实，且本仓库从未产生过这样的 tag，因此它只说明"watch 试过了"，不证明调度被重置。

前提条件：仓库是公开的（否则 60 天无活动后 schedule 会被停用）；默认 `GITHUB_TOKEN` 可写；
`main` 不要求 token 创建的 PR 无法满足的状态检查，因为那样的推送不会触发工作流。

成本：安静的一次运行只是一个耗时数秒的 `detect` job；有新发布则要付五阶段构建（实测端到端
18 分钟）加 `locks`、`merge` 与 `publish`；watch 两个升级闸门都不跑，因此绿色 watch 只证明
构建与合并，不证明该发布能装在上一版之上。

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

会话步骤用 `owenthereal/action-upterm` 并设 `detached: true`，把连接行发布到运行摘要页与
`debug-session` 产物：

```sh
ssh session:<token>@uptermd.upterm.dev
ssh -i ~/.ssh/id_ed25519 session:<token>@uptermd.upterm.dev   # 非默认密钥
```

`limit-access-to-actor: true` 意味着只有触发该次运行的用户在 GitHub 上登记的 SSH 公钥能连；
该账号没有公钥时谁都连不上。这个字符串只是定位会话，私钥才是凭据——把它、`join-command` 与
`ssh-config` 当作同一件凭证，任何一条都不要外贴。`full-access: true` 让 shell 真正可用，
而它只授予一个随 job 一起销毁的 VM。

边界：会话步骤上限 10 分钟，keep-alive 步骤 150 分钟（140 分钟时自停），job 240 分钟，
远在 GitHub 的 6 小时硬上限之内。时长来自步骤与 job 上的 `timeout-minutes`，从不来自 shell
字面量，`scripts/check_design.py debug-ssh` 断言这一安排。SSH 连接断开不会结束会话——在
shell 里 `exit`，或取消运行，才会。运行摘要、`debug-session` 产物（保留一天）与
`debug-<stage>-logs`（保留七天）是残留；日志不再需要后删除该次运行。

## CI 文本契约

CI 对人说的每句话都是契约，因为运行页只被读一次，而且是在压力下。七条规则，由
`tests/modules/ci/test_ci_text_conventions.sh` 断言：

1. **界面上只用英文。** `.github/workflows/*.yml`、`.github/actions/*/action.yml` 与
   `scripts/ci/*.sh` 里每个非注释行都是 ASCII。中文只出现在 `docs/*.zh-CN.md`。
2. **标签不是句子。** 结尾没有句号或感叹号，首尾没有空格。工作流与 job 标签用 Title Case：
   每个槽都以大写词开头并以大写词结尾，只有 `a an the and of for to in on by or` 这些短
   冠词、介词与连词在槽内保持小写。步骤标签与所有句子保持句首大写（sentence case）。
3. **长度上限。** 工作流或 job 名 40 字符，步骤名 60 字符，issue、PR 或发布标题 80 字符。
4. **每一层一种语法槽。** 入口是 `Firmware CI - <role>`；可复用文件是
   `S<n> <semantic>` 或简短角色短语；阶段 job 是 `S<n> <semantic> - <what it proves>`；
   步骤是 `<Verb phrase>` 或 `<Marker> - <claim>`；分隔符恰好是 ` - `。工作流与 job 的每个槽
   都填 Title Case——每个槽以大写词开头、以大写词结尾，`a an the and of for to in on by or`
   在槽内保持小写；步骤保留动词首字母大写、其余仍是句首大写（sentence case）。
5. **固定摘要表。** 六个表头，不能有第七个：`stage | verdict | key line | artifact and
   sha256 | next command`、`stage | verdict | duration | artifact`、`field | value`、
   `job | result`、`artifact | size | sha256`、`file | written this run`。
6. **固定标题模板。** `[auto-release] <version>`、`chore(ci): pin upstream <version>`、
   `# Upstream <version> (pin <old> -> <new>)`，以及由 `tag-policy` 派生的两个发布标题。
7. **结构不是文本。** 改文字不得改运行。`tests/fixtures/ci-structure-fingerprint.txt` 为每个
   结构 token 保存一行排序结果，因此一次措辞批次让它逐字节不变；它若变化，diff 会点名移动
   的那个键。

命名简述：分隔符只有一个 ` - `；阶段是 `S<n> <semantic>`；每个工作流与 job 标签都是
Title Case；步骤不带阶段号；不决定阶段成败的步骤以 ` - advisory` 结尾。

## 限制

- 被跳过的阶段或闸门从不被报告为通过。
- 流水线不编译内核：它消费官方 rootfs、内核与 btrfs 模块，因此上游构建内部的缺陷超出它的
  能力范围。
- 自动线无法用自己的运行来证明自己：被停用的 schedule 不产生任何运行，所以必须从外部用
  `gh api repos/:owner/:repo/actions/workflows/<id> --jq .state` 检查。
- 本仓库的发布不可撤销：tag 不移动，因此坏发布只能被后继版本取代，不能被重写。

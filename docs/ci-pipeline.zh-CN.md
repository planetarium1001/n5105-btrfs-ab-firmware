# CI 流水线

十五个 workflow 文件、四个入口、五个阶段和一套固定的产物。十五个里有十一个是 reusable
（只有 `workflow_call`），自己永远起不来一次 run；能起 run 的四个是 `ci.yml`、`ci-debug.yml`、
`release.yml` 和 `upstream-watch.yml`。所有判断都在 `scripts/ci/`，所以一个阶段不依赖 GitHub
也能复现。这一页是地图：该跑哪个 workflow、每个阶段证明什么、哪个文件才是该写进磁盘的那一个、
以及怎么在本机跑一个阶段。阶段脚本本身的说明在
[`../scripts/ci/README.md`](../scripts/ci/README.md)；两条发布线见
[`ci-release-lines.zh-CN.md`](ci-release-lines.zh-CN.md)。

## Workflow 总表

| Workflow 文件 | 触发 | 是否发布 | 产物 | 什么时候跑它 |
|---|---|---|---|---|
| `ci.yml` | push 到 `main`、PR 到 `main`、`workflow_dispatch`（`stage`、`upstream_version`）、`workflow_call` | 否 | 自己没有产物：它调用各阶段，产物由阶段上传 | 日常验证，或者重跑失败 run 里的单个阶段（`-f stage=s3`） |
| `ci-resolve.yml` | 仅 `workflow_call` | 否 | `logs-resolve` | 不要手跑：由 `ci.yml` 调用 |
| `ci-fetch.yml` | 仅 `workflow_call` | 否 | `upstream-files`、`logs-fetch` | 不要手跑：由 `ci.yml` 调用 |
| `ci-assemble.yml` | 仅 `workflow_call` | 否 | `payload-upgrade`、`logs-assemble` | 不要手跑：由 `ci.yml` 调用 |
| `ci-verify.yml` | 仅 `workflow_call` | 否 | `logs-verify` | 不要手跑：由 `ci.yml` 调用 |
| `ci-s1.yml` | 仅 `workflow_call` | 否 | `evidence-s1`、`logs-s1` | 不要手跑：由 `ci.yml` 调用 |
| `ci-s2.yml` | 仅 `workflow_call` | 否 | `evidence-s2`、`logs-s2`、`image-probe`（永远不要写进磁盘） | 不要手跑：由 `ci.yml` 调用 |
| `ci-s3.yml` | 仅 `workflow_call` | 否 | `evidence-s3`、`logs-s3`、`image-install` | 不要手跑：由 `ci.yml` 调用 |
| `ci-s4.yml` | 仅 `workflow_call` | 否 | `evidence-s4`、`logs-s4` | 不要手跑：由 `ci.yml` 调用 |
| `ci-s5.yml` | 仅 `workflow_call` | 否 | `evidence-s5`、`logs-s5` | 不要手跑：由 `ci.yml` 调用 |
| `ci-report.yml` | 仅 `workflow_call` | 否 | `logs-report`；run 页面的表和结论 | 不要手跑：由 `ci.yml` 调用 |
| `ci-debug.yml` | 仅 `workflow_dispatch`（`stage`、`boot_timeout`） | 否 | `debug-session`、`debug-<stage>-logs` | 需要一双眼睛盯着某个阶段时，在 runner 上开 upterm 会话 |
| `release.yml` | push `v*` tag | 是，经由 `release-publish.yml` | 三个发布资产 | 发我们自己的版本：推一个 `v*` tag（[代码线](ci-release-lines.zh-CN.md)） |
| `release-publish.yml` | 仅 `workflow_call`（`tag`、`tag-policy`、`title`、`dry-run` 等） | 是；`dry-run: true` 只建成 draft | `n5105-ab-<upstream>-install.img.gz`、`n5105-ab-<upstream>-upgrade.tar`、`SHA256SUMS` | 不要手跑：`release.yml` 与 `upstream-watch.yml` 调用它 |
| `upstream-watch.yml` | `schedule`（`0 20 * * *`）与 `workflow_dispatch`（`version`、`dry-run`、`base`） | 是，打裸版本号 tag | 一个以 `<upstream version>` 命名的 release，或者一个 `[auto-release]` Issue | 每日上游发布，或对它做彩排 |

- **reusable 与入口。** 十一个文件只声明 `workflow_call`，因此起不了 run，也完全不声明
  `concurrency`：被调用的 workflow 跑在调用者的 run 里，而嵌套的 `concurrency` 组会让这次调用
  静默消失（job 根本不出现在图里）。四个入口里只有两个声明了组：`ci.yml` 与 `ci-debug.yml`；
  `release.yml` 与 `upstream-watch.yml` 一个都不声明，因为它们都调用 `ci.yml`，会被上面这条规则
  吃掉那次调用。
- **lane。** 这两个组是 `ci-<workflow>-<lane>-<ref>`，lane 取自
  `github.event_name == 'workflow_dispatch' && 'manual' || 'auto'`，`cancel-in-progress` 只对自动
  lane 为真。所以同一 ref 上两次手动派发是排队，不是互相取消；push 也不会取消派发。
  `ci-debug.yml` 是刻意的不同：组里照样带 lane，但两条 lane 都写 `cancel-in-progress: true`，
  因为第二次会话应该顶掉第一次，而不是排在 290 分钟的会话后面等。
- **超时。** 每个自己跑步骤的 job 都带 `timeout-minutes`：`resolve` 10、`fetch` 20、
  `assemble` 35、`verify` 30、S1 30、S2 40、S3 45、S4 与 S5 75、`report` 20、`ci.yml` 的
  `versions` 5、debug job 290（keepalive 150）。只调用 reusable workflow 的 job 设不了超时，
  所以 `release.yml` 以及 `upstream-watch.yml` 的 `build`、`publish` 用的是被调 workflow 的预算。
- **第三方 action** 全部 pin 到 40 位 commit sha，绝不跟浮动 tag：用 runner 凭据跑的东西必须是
  被审过的那一份。重复出现的步骤组（准备 runner、跑阶段脚本、上传证据、摘要、QEMU 引导、
  actionlint）是 `.github/actions/` 下的六个 composite。

## 五个阶段

每个阶段是一个 reusable workflow，它的 job 标签在图里和 job 列表里是同一个字符串。

| 阶段 | 标签 | 它证明什么 | 它失败会怎样 |
|---|---|---|---|
| S1 | `S1 probe - kernel mounts btrfs` | 官方内核能在我们的 initramfs 里加载官方 btrfs 模块闭包并挂载 btrfs | 后续任何一个阶段都不能再指望 `switch_root` 之前有 btrfs |
| S2 | `S2 image - four partitions` | 四分区几何、ESP 内容与 GPT PARTNAME，且是 guest 里回读出来的 | 什么都装不了：安装时写下的布局是错的 |
| S3 | `S3 boot - layered root` | 引导 initramfs 合成 overlay 根并到达 `switch_root`，连续两次 | 任何 slot 都起不来，镜像不可安装 |
| S4 | `S4 slots - A/B state machine` | 四次引导走完提交、放弃与回滚，含健康检查 | A/B 切换未被证明：更新可能卡在坏 slot 上 |
| S5 | `S5 upgrade - upgrade and reclaim` | 载荷升级、降级启动与回收，四次引导 | 更新未被证明，包括可写分区整个坏掉的那种情况 |

每个阶段只打印一行冻结的 judge 行，行的形状就是契约：`S1-RESULT=…` 到 `S5-RESULT=…`。显示名
可以改，token 不能改。

## 产物：每一个是干什么用的

| 产物 | 由谁产出 | 内容 | 用途 |
|---|---|---|---|
| `image-install` | S3 | `n5105-ab-<upstream>-install.img.gz` | 该写进磁盘的镜像。发布作业重发的就是这份字节。 |
| `image-probe` | S2 | 同样几何、但带 S1 探针 initramfs | **永远不要写进磁盘**：它找 `/dev/vda`，在真机上直接关机 |
| `payload-upgrade` | assemble | `payload.tar`、清单与校验日志 | 运行中的机器上 `ab-upgrade` 消费的东西 |
| `upstream-files` | fetch | 上游 rootfs、内核与 btrfs 模块 | 输入；留下来是为了不联网也能复核一次 run |
| `evidence-s1` … `evidence-s5` | 各阶段 | 串口日志、initramfs、清单、夹具转储 | 该阶段被判定的结构化证据 |
| `logs-<stage>` | 各阶段 | 该阶段自己的日志与诊断摘要 | 阶段失败时唯一要翻的地方 |
| `debug-session`、`debug-<stage>-logs` | 调试 workflow | SSH 命令与手动会话的引导日志 | 仅用于人工调试 |

发布出来的文件叫 `n5105-ab-<upstream>-install.img.gz` 或
`n5105-ab-<upstream>-upgrade.tar`：板型、产品线、上游基线、角色。我们自己的发版计数器不在
文件名里 —— 它所在的 GitHub Release 已经带着了。`release-notes.md` 写在资产旁边、成为 release
正文，所以一次发布是三个资产、四个文件。

## 怎么读一个 run 页面

- 每个阶段 job 结尾有一个**阶段摘要**：一张表，五列 `stage`、`verdict`、`key line`、
  `artifact and sha256`、`next command`。这个阶段的问题在这张表里就有答案，日志是细节。
- **report** job 出整条流水线的一张表：`stage`、`verdict`、`duration`、`artifact`，后面是折叠
  起来的 judge 行。耗时取自 Actions API，是真实的 job 墙钟时间。
- 失败的 run 会把要紧的话写在第一行：卡在哪个阶段，以及看原因的那条命令。

## 如何本地复现一次 CI

阶段脚本读环境变量，把 scratch 写在 `$CI_TMP_ROOT` 下。`GITHUB_OUTPUT` 与
`GITHUB_STEP_SUMMARY` 都是可选的，`CI_OUTPUT_ENV` 把阶段输出写成 `KEY=VALUE` 文件给下一段加载，
全程不需要任何 GitHub 客户端。这也是为什么一部分能在笔记本上跑，另一部分必须有 Linux。

### 只解析版本

```sh
export CI_TMP_ROOT=/tmp/ci
mkdir -p "$CI_TMP_ROOT"
CI_OUTPUT_ENV="$CI_TMP_ROOT/resolve.env" bash scripts/ci/resolve.sh
```

它会打印 `[resolve] upstream version 25.12.2 (source: pin)` 与
`[resolve] cache key upstream-25.12.2-<hash>`，并把后面每个阶段都要的十四行
`KEY=VALUE` 写进 `$CI_TMP_ROOT/resolve.env`。它需要网络：要下载该 release 的 `sha256sums`
和它的包清单。那个 hash 不是可以照抄的常量：它覆盖解析出的摘要、工具版本，以及每个
`scripts/ci/*.sh` 与 `.github/workflows/*.yml` 的内容，这些一变它就变。

`CI_UPSTREAM_VERSION` 指定另一个版本，`latest` 解析镜像站上最新的一个，
`CI_UPSTREAM_VERSION_PIN` 绕过 pin 文件；三者都不给时由 pin 决定。

### 解析，然后把上游文件下载下来

```sh
export CI_TMP_ROOT=/tmp/ci
mkdir -p "$CI_TMP_ROOT"
CI_OUTPUT_ENV="$CI_TMP_ROOT/resolve.env" bash scripts/ci/resolve.sh
CI_RESOLVE_ENV="$CI_TMP_ROOT/resolve.env" bash scripts/ci/fetch.sh
```

`fetch.sh` 自己加载 resolve 的输出，按摘要逐个校验，把 `rootfs.tar.gz`、`kernel.bin` 与 btrfs
模块留在 `$CI_TMP_ROOT/fetch/upstream`。

组装 payload 还需要四个 resolve 与 fetch 不产出的输入，缺第一个就停：

| 变量 | 从哪来 |
|---|---|
| `CI_PLATFORM_VERSION` | `tr -d '[:space:]' < VERSION`；故意没有默认值 |
| `CI_INITRAMFS` | `bash scripts/ci/initramfs.sh` |
| `CI_PLATFORM_RUNTIME_DIR` | `bash scripts/ci/platform-runtime.sh` |
| `CI_BOOT_SRC` | `bash scripts/ci/esp-prepare.sh`（默认 `$CI_TMP_ROOT/esp`） |

`assemble.sh` 自己还会导出 `CI_REQUIRE_BOOTLOADER=1`：带不上引导器的 payload 是构建设败，
不是一条警告。它还要读 `CI_UPSTREAM_VERSION` 与 `CI_KERNEL_PACKAGE`，而它不像 `fetch.sh` 那样
自己加载 `resolve.env`，所以本机跑时要显式传进去：

```sh
CI_UPSTREAM_VERSION="$(sed -n 's/^upstream_version=//p' "$CI_TMP_ROOT/resolve.env")" \
  CI_KERNEL_PACKAGE="$(sed -n 's/^kernel_package=//p' "$CI_TMP_ROOT/resolve.env")" \
  bash scripts/ci/assemble.sh
```

### 复现一个 QEMU 阶段

QEMU 阶段读 `CI_QEMU_MODE`（`kernel`、`uefi` 或 `uefi-disk`）、`CI_QEMU_TIMEOUT` 与
`CI_JUDGE_PREFIX`，再加上前面阶段用默认名字写下的文件：

```sh
export CI_TMP_ROOT=/tmp/ci
CI_QEMU_MODE=uefi-disk CI_QEMU_TIMEOUT=900 CI_JUDGE_PREFIX=S3-RESULT \
  CI_KERNEL="$CI_TMP_ROOT/fetch/upstream/kernel.bin" \
  CI_INITRAMFS="$CI_TMP_ROOT/initramfs/initramfs.cpio.gz" \
  CI_QEMU_DISK="$CI_TMP_ROOT/disk/n5105-ab-image.img" \
  bash scripts/ci/qemu-smoke.sh
```

每个阶段脚本开头都有一段 `Inputs (environment)` 注释列出它读什么，末尾一行 `Outputs` 说明它发布
什么；[`../scripts/ci/README.md`](../scripts/ci/README.md) 是同一份清单的上一层。动手前读你要跑
的那个脚本的头部，那才是该阶段权威的变量清单。

### 或者把单个阶段交给 runner

```sh
gh workflow run ci.yml --ref main -f stage=s3 -f upstream_version=25.12.2
```

`stage` 只接受 `all`、`fetch`、`assemble`、`s1`、`s2`、`s3`、`s4`、`s5`、`verify`；
`upstream_version` 可以省略，省略就用 pin。这次 run 会把图上其他 job 留成 skipped，所以该阶段
是由同一批脚本、同一组输入判定的，只是跑在有 QEMU 的机器上。

### 本机能跑什么、不能跑什么

| 部分 | 在 macOS 上 | 为什么 |
|---|---|---|
| `bash scripts/ci/resolve.sh` | 能跑 | 只要 `curl` 和 shell；没有 `sha256sum` 时 `lib.sh` 回落到 `shasum -a 256` |
| `bash scripts/ci/fetch.sh` | 能跑 | 同样的工具，外加网络 |
| `bash scripts/ci/assemble.sh` | 不能 | 需要 initramfs、摆好的 btrfs 工具与一棵 ESP 树，也就是下面那些 Linux 阶段 |
| `bash scripts/ci/verify.sh` | 不能 | 会报 `actionlint: fail` 与 `shellcheck: fail`，因为缺 linter 按设计就是阶段失败 |
| `python3 scripts/check_design.py all` | 能跑 | 就是 `verify.sh` 里的那组检查，不依赖 linter |
| `./tests/run.sh --module ci` | 能跑 | CI 测试模块 |
| S1 到 S5、`disk.sh`、`qemu-smoke.sh` | 不能 | `ci_require_cmd` 要 `qemu-system-x86_64`、`losetup`、`sfdisk`、`mkfs.vfat`、`mkfs.btrfs`、`chattr`、`blkid`、`timeout`；macOS 上一个都没有 |

### 常见报错对照

| 症状 | 通常意味着 | 怎么办 |
|---|---|---|
| 先出现 `[ci] WARNING: ignoring invalid upstream pin in .github/upstream-pin.conf: …`，接着是 `upstream version 25.12.2 (source: pin)` | pin 那行不是 `X.Y.Z`，于是 `ci_upstream_pin_read` 回落到内置的 `CI_UPSTREAM_PIN_DEFAULT`，这次 run 构建的是没人 pin 过的版本 | 让 `.github/upstream-pin.conf` 里只留一行 `UPSTREAM_VERSION=X.Y.Z`；这也是 `ci_write_upstream_pin` 唯一会写的形式 |
| `[resolve] ERROR: invalid upstream version: '25.13' does not match ^[0-9]+\.[0-9]+\.[0-9]+$` | 显式给的 `CI_UPSTREAM_VERSION`（或 `-f upstream_version=`）不是正式版号 | 给一个正式的 `X.Y.Z`，或者给 `latest`，或者什么都不给以使用 pin |
| 没有报错，但 scratch 文件出现在 `/tmp/ci` 而不是你指定的目录 | `CI_TMP_ROOT` 没导出；`ci_stage_init` 回落到 `${RUNNER_TEMP:-/tmp}/ci` | 在跑第一个脚本前 `export CI_TMP_ROOT=/tmp/ci`，让所有阶段共用一棵树 |
| `no boot source at … and CI_REQUIRE_BOOTLOADER=1: a payload without the bootloader cannot bring one forward` | payload 阶段找不到可取的 ESP 树，而 `assemble.sh` 正是为这种情况导出 `CI_REQUIRE_BOOTLOADER=1` | 先跑 `bash scripts/ci/esp-prepare.sh`（它写 `$CI_TMP_ROOT/esp`），或把 `CI_BOOT_SRC` 指向一棵带 GRUB EFI loader 的树 |
| `CI_LOCK_STRICT=1: asserting the pinned lockfile (25.12.2) for the 25.13.0 build`，接着一条 `mirror publishes …, lockfile pins …` | 在打开 pin 契约的前提下，要求构建一个已提交 lockfile 并不描述的版本 | 一次性构建别的版本就去掉 `CI_LOCK_STRICT`（它会在 `$CI_TMP_ROOT/locks/` 下派生自己的 lockfile）；否则用 `--write-lock` 刷新 lockfile 并审 diff |
| `verify.sh` 里 `actionlint: fail` 与 `shellcheck: fail`，同时 `design: ok`、`python: ok` | 两个 linter 都不在 `PATH` 上；阶段把缺失当失败，从不跳过 | `brew install shellcheck actionlint`，或把 `CI_ACTIONLINT_BIN` 指向一个 actionlint 可执行文件；只查文档就用 `python3 scripts/check_design.py all` |
| 真机在 GRUB 菜单关机，串口日志最后一行是 `S1-RESULT=fail reason=no-device-node` | 写进磁盘的是 `image-probe`，也就是 S2 的夹具，它找的是 `/dev/vda` | 写 `image-install`（S3）或发布资产 `n5105-ab-<upstream>-install.img.gz` |

## 构建非 pin 版本

手动入口接受 `upstream_version` 输入，流水线会端到端拉取那个版本。三个 lockfile
（`kmod-closure.json`、`initramfs-tools.lock.json`、`runtime-closure.json`）钉的是一个版本的
程序，所以为别的版本构建时，会在 `$CI_TMP_ROOT/locks/` 下派生自己的副本、对副本做断言，并在 run
页面上告警。已提交的 lockfile 仍是 pin 的契约；`CI_LOCK_STRICT=1` 让所有版本回到硬失败。

同一 ref 上两次派发**不会**互相取消：concurrency 组带 lane 段，手动 run 排队，只有自动 run 会
取消它顶替掉的那次自动 run。多版本矩阵是一组**串行**的 run。

在真机上消费这些构建的驱动见 [`device-matrix.zh-CN.md`](device-matrix.zh-CN.md)。发布到底是怎么
发生的 —— 代码线与上游自动线 —— 见 [`ci-release-lines.zh-CN.md`](ci-release-lines.zh-CN.md)。

## 阶段失败时

1. 先看 report 的第一行，它点名了阶段。
2. 打开那个阶段的摘要块：`key line` 是判定的那行 judge 行，`artifact and sha256` 说明该下载什么。
3. `next command` 要么是 `gh run view <run> --log-failed`，要么是本地复现（`bash
   scripts/ci/qemu-smoke.sh`、`bash scripts/ci/disk.sh`、`bash scripts/ci/s5-phase.sh`）。阶段脚本
   本地不需要任何 GitHub 工具；它们读哪些变量、哪些笔记本上跑不了，见上面「如何本地复现一次 CI」。
4. 最后才翻日志；日志不在了就取 `logs-<stage>`。

## 命名规则

- 只用一个分隔符 ` - `（空格-连字符-空格）。workflow、job、步骤名里不出现括号、冒号或中点。
- 阶段是 `S<n> <语义名>`（`S2 image`）；job 在后面补上它证明什么（`S2 image - four partitions`）。
- 步骤名是祈使句，不带阶段号：上面的 job 已经说明它属于哪个阶段。
- 不构成闸门的步骤用 ` - advisory` 标明。

上面这些是 [`ci-text-contract.zh-CN.md`](ci-text-contract.zh-CN.md) 的简写版；长度上限、
固定表头、标题模板与结构指纹都在那一页，并由 `tests/modules/ci/test_ci_text_conventions.sh`
断言。这一页是地图。

## 逻辑在哪里

`.github/workflows/` 只做编排：检出、跑一个脚本、上传、收集诊断。所有判断都在 `scripts/ci/`，
所以一个阶段能用 workflow 传的同一组输入在本地复现。两个渲染器 —— `stage-summary.sh` 与
`report.sh` —— 是唯一可以改标签而不改结论的 CI 文件。

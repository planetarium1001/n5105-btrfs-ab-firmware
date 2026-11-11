# CI 流水线

这条流水线是三个独立的 GitHub workflow、五个阶段和一套固定的产物。这一页是地图：哪个
workflow 什么时候跑、每个阶段证明什么、哪个文件才是该写进磁盘的那一个。阶段脚本本身的说明在
[`../scripts/ci/README.md`](../scripts/ci/README.md)。

## 三个入口

| Workflow | 触发 | 做什么 |
|---|---|---|
| `Firmware CI - build and validate` | push 到 `main`、PR、手动 | 跑五个阶段与静态检查，最后给一个结论。产出 `image-install`。 |
| `Firmware CI - release` | tag `v*` | 调用验证流水线，重新打开它产出的镜像，不是可引导的就拒绝，然后发布。分支上永不发布。 |
| `Firmware CI - debug session` | 仅手动 | 备好同一份镜像，把 runner 交给一个可 SSH 登录的交互会话。不判定、不发布产物，只留一份短期日志。 |

三个名字共享前缀是有意的：在 Actions 列表里它们挨在一起，"哪个验证、哪个发布、哪个只是调试"
不用点开就能分清。

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
文件名里 —— 它所在的 GitHub Release 已经带着了。

## 怎么读一个 run 页面

- 每个阶段 job 结尾有一个**阶段摘要**：一张表，五列 `stage`、`verdict`、`key line`、
  `artifact and sha256`、`next command`。这个阶段的问题在这张表里就有答案，日志是细节。
- **report** job 出整条流水线的一张表：`stage`、`verdict`、`duration`、`artifact`，后面是折叠
  起来的 judge 行。耗时取自 Actions API，是真实的 job 墙钟时间。
- 失败的 run 会把要紧的话写在第一行：卡在哪个阶段，以及看原因的那条命令。

## 阶段失败时

1. 先看 report 的第一行，它点名了阶段。
2. 打开那个阶段的摘要块：`key line` 是判定的那行 judge 行，`artifact and sha256` 说明该下载什么。
3. `next command` 要么是 `gh run view <run> --log-failed`，要么是本地复现（`bash
   scripts/ci/qemu-smoke.sh`、`bash scripts/ci/disk.sh`、`bash scripts/ci/s5-phase.sh`）。阶段脚本
   本地不需要任何 GitHub 工具，它读的环境变量见 [`../scripts/ci/README.md`](../scripts/ci/README.md)。
4. 最后才翻日志；日志不在了就取 `logs-<stage>`。

## 命名规则

- 只用一个分隔符 ` - `（空格-连字符-空格）。workflow、job、步骤名里不出现括号、冒号或中点。
- 阶段是 `S<n> <语义名>`（`S2 image`）；job 在后面补上它证明什么（`S2 image - four partitions`）。
- 步骤名是祈使句，不带阶段号：上面的 job 已经说明它属于哪个阶段。
- 不构成闸门的步骤用 ` - advisory` 标明。

## 逻辑在哪里

`.github/workflows/` 只做编排：检出、跑一个脚本、上传、收集诊断。所有判断都在 `scripts/ci/`，
所以一个阶段能用 workflow 传的同一组输入在本地复现。两个渲染器 —— `stage-summary.sh` 与
`report.sh` —— 是唯一可以改标签而不改结论的 CI 文件。

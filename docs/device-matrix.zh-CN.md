# 真机矩阵

**中文** | [English](device-matrix.md)

`scripts/device/` 通过 SSH 驱动一台真机，把一次升级、降级或重启变成一行 PASS/FAIL/GAP。
它存在的原因是一个槽位可以启动却仍然是坏的：只有状态字段、面包屑与存活的数据标记三者合起来，
才能回答"这次跳变是否留下了一台可启动的机器"。

前置条件：一台能以 `root` 通过 SSH 到达的机器、手边的 SSH 密钥，以及一个存放待跳变 payload
的目录。

## 矩阵可以使用的版本

只有一条线：25.x / apk 线。早于 25 的版本会被拒绝，任何来自 opkg 时代的树同样被拒绝，因为
两个时代不共享包管理器、防火墙模型或内核模块布局。`scripts/ci/upstream-watch.sh` 已经拒绝
钉住主版本低于 25 的版本，矩阵受同一条规则约束：`matrix.sh` 检查 payload 的
`platform-release`，并用一行明确的说明拒绝 `-` payload，而不是让它跑起来再在某个看起来像
产品缺陷的地方失败。

## 每次跳变后断言什么

A/B 模型只能由真实上游版本证明，而不是靠改写 manifest 里的版本字符串。矩阵在流水线真正能构建
的版本之间跳变，并在每次跳变后断言同一组不变量：

- `boot=ok` **且** `esp=ok`——一次读不到 ESP 的启动不算通过；
- `generation` 严格增长，`pending=none`；
- 两个槽位的 upper 都存在，且没有任何 `@overlay-*` 在被引用之外存活；
- 共享分区上的用户标记与 `/etc/config` 里的配置标记仍在；
- 启动日志带 `stage=healthcheck-done result=ok` 与提交行。

最后一条最容易读错：当前这次启动的标记在轮转后位于 `boot-1.log`，所以驱动依次查
`boot-0.log`、`boot-1.log`、`ab-slot log --prev`，并记录是哪个文件给出了答案。

## 运行

```sh
scripts/device/matrix.sh --dry-run                      # 打印计划，不碰任何东西
scripts/device/matrix.sh --case M3 --payload-dir <dir>
scripts/device/matrix.sh --payload-dir <dir> --resume    # 跳过已经通过的用例

scripts/device/full-test.sh --dry-run --expect <version>              # 整套，先看计划
scripts/device/full-test.sh --yes --expect <version> --payload-dir <dir>
```

`--payload-dir` 里放名为 `payload-<version>.tar` 的 payload。结果追加写入 `--results`，格式
为 `case<TAB>verdict<TAB>evidence<TAB>note`，每个用例一行，因此中断的运行靠读文件续跑，而
不是靠记忆。

环境取自 `AB_HOST` 与 `AB_KEY`。SSH 调用总是带 `ControlMaster=no`、`ControlPath=none` 与
被忽略的 `known_hosts`：重刷过的机器会呈现新的主机密钥，而运行驱动的沙箱没有可写的
`~/.ssh`。

交互式登录与这些非交互调用是两个问题，它有自己的驱动：`scripts/device/login-probe.sh` 在
整个会话期间保持客户端 stdin 打开，因为把 `/dev/null` 重定向进 `ssh -tt` 的探针在这个镜像
上会报假失败（dropbear 2025.89，见 [troubleshooting.zh-CN.md](troubleshooting.zh-CN.md)）。

## 用户场景

`scenarios.sh` 回答另一个问题：用户装过包、写过文件、改过设置——一次版本跳变能不能把这一切
留住，软件还能不能跑？

| 用例 | 构建什么 | 评判什么 |
|---|---|---|
| S1 preinstall | 来自该版本自己 apk 索引的 LuCI 应用、一个命令行工具与一个 kmod | 已安装版本的快照、索引没有提供哪些包，以及一个装/跑/卸循环不留残余文件 |
| S2 user state | `/data` 上的文件与目录树、两个假 docker 包、一个额外 `uci` 段、主机名、时区、一条防火墙规则 | 每个文件按 sha256、目录树按条目数、每个设置按 `uci get`，以及真实 `network reload` 之后 SSH 仍有应答 |
| S3 / S4 jump | 由低到高与由高到低，预装软件在位 | 每跳之后同样的数据、配置、软件包、挂载与服务检查，且该跳落在 `packages=aligned packages_reason=none` |
| S5 ledger | 最终内核 | 哪些已装包仍然有效、哪个 kmod 必须重装，以及平台层报告了什么 |
| S6 boot tools | 什么都不建，只读 | ESP 上的 `vmlinuz-<slot>`/`initrd-<slot>` 与 payload 的 `kernel.bin`/`initramfs.cpio.gz` 逐字节一致，平台层工具与 `platform.tar` 一致 |
| S7 releasefeeds | 每个版本从它自己的 feed 列表取一个包，然后跳变 | 每个版本都能从自己的 feed 安装、diff 表点名了什么移动了，以及无法提供某个包的 feed 被报告为 feed 问题（GAP）而不是坏机器 |
| S8 badconfig | 故意四个坏配置：点名不存在设备的网络段、`fw4` 无法翻译的防火墙规则、被截断的 docker `daemon.json`，以及返回 404 的 apk feed | 每一类都被拒绝或可见地降级并且恢复、该类自己的备份在写之前已在 `/data` 上并逐字节还原，且第二次 `apk update` 仍能区分"feed 关闭"与"机器没有网络" |

两条规则让这些用例诚实：

- **不用旧格式做判断。** 包名来自该版本自己的 apk 索引，配置写成对随镜像文件的改动，因为流传
  的 23/24 时代片段描述的是 opkg 与另一套防火墙模型。
- **机器留有退路。** S2 在 reload 之前先安排自己的回滚（用 `setsid`，没有它时用
  `start-stop-daemon -b`），由 `/tmp/ab-scen-net.ok` 确认；两者都安排不了的机器根本不
  reload，被跳过的那一半记为 FINDING，而不是"没看的通过"。

ABI 只报告、不评判：为另一个内核构建的 kmod 在 apk 世界里很正常，因此不匹配记为带重装清单的
`FINDING:`，从不单独改变结论。

## 社区软件样本

A/B 事务最初是在一台额外软件只有测试套件自己装的五个包的机器上被证明的。真机不是那台机器：
人们会装 LuCI 主题、软件商店、代理应用，并编辑这些应用自己的 `/etc/config` 文件。这一轮把
这层东西放到机器上再跳变，只回答一个问题：事务是否仍然提交，样本是否保住自己的配置？

- `scripts/device/software-probe.sh` 安装 `tests/fixtures/software-samples.json` 里列出的
  样本（`--manifest` 覆盖清单，`--sample` 缩小范围）。每个样本行是带落定版本的 PASS，或带
  原因与重试命令的 GAP：挂掉的第三方源、ABI 与本内核不匹配的内核模块，都是 GAP 而绝非通过。
- `--baseline <tag>` 在跳变前、`--compare <tag>` 在跳变后，用与其他驱动相同的快照助手记录并
  比较样本自己的配置（比较取值，而不只是文件哈希）。
- `--cleanup` 移除样本、它们的配置以及它添加的源，让机器回到产品基线。第三方源只写进设备的
  `/etc/apk/repositories.d/`，绝不写进镜像、payload 或 `scripts/ci/net-defaults.conf.in`。
- `scripts/device/badconfig-probe.sh` 写入人能造出的同类坏配置（坏的 `daemon.json`、坏的
  UCI 段、fw4 会告警的防火墙规则、假的订阅 URL），并分别评判两件事：谁拒绝或还原了它，以及
  还有没有别的东西跟着反应。

两条限制先说清楚：样本清单只覆盖 25.x，且样本是测试 fixture 而不是产品内容——本仓库没有任何
东西依赖它们，发布资产在装或不装样本时逐字节相同。

## 整套：一种顺序，一个结论

`full-test.sh` 按一种顺序运行上面的驱动——外加两个只回答自己问题的
（`docker-probe.sh`、`release-verify.sh`）——并把各阶段的结果文件归约成一个结论：

| 阶段 | 回答什么 | `--only` 的用例 |
|---|---|---|
| preflight | 密钥文件、SSH 可达性、平台身份、可用空间、payload 目录 | 总是运行 |
| probes | 一台还没被人碰过的机器的基线 | `grow network wan22 key platform adapter initrd packages` |
| feed-install | feed 提供了候选，机器吃下去了（默认 `--case all`：check、pin、install） | `check`、`install`、`pin`、`both`、`all` |
| matrix | M1..M7：版本跳变是否留下可启动的机器 | `M1`..`M7` |
| scenarios | S1..S8：用户数据与软件是否活下来 | `S1`..`S8` |
| docker | D1：真实 docker 负载的基线（经国内镜像站两个镜像、一个容器、一个命名卷、一个提交镜像） | `D1` |
| package-revert | P1..P4：包快照、离线回退、拒绝被篡改的 payload、拒绝来自另一个 base 的记录。`U1`（包升级确实搬动了）从不在默认集合里——它会安装 | `P1`..`P4`、`U1` |
| recovery | 坏版本自行回滚 | `R1`..、`B1`.. |
| power-cut | 被中断的候选启动不会被永久重试 | `I1`、`I2` |
| docker-after | D2 / D3：镜像与产物活过了切换，`@docker`/`@data` 保住了自己的子卷身份 | `D2`、`D3` |
| release | 已发布的版本：tag、四个资产、`SHA256SUMS` 与 `index.txt` | `release`，或它的某个子句名 `verdict`/`sums`/`index`——任何一个都会选中整个阶段，因为 `release-verify.sh` 每次都检查全部子句 |

顺序是依赖顺序：

- **`feed-install` 排在 `matrix` 与 `scenarios` 之前。** feed 必须提供比正在运行的更新的
  东西，而 matrix 与 scenarios 会把机器带到最新版本，所以排在它们之后的 feed-install 会在
  一台完全健康的机器上按构造失败。
- **`docker` 是围绕版本跳变的两个阶段，仍然是同一个脚本。** D1 在 matrix 与 scenarios 之前
  取基线，因为那两次跳变正是基线要活过的东西；D2 与 D3 在跳变之后立即评判同一个存储。两个
  窗口都指向同一个 `<results>/docker-snapshots` 目录：D1 写 `before.snapshot`，
  docker-after 读回并写 `after.snapshot`。它保持为一个驱动，是因为跳变两侧的采集与比较必须
  是同一份代码。
- **`release` 排在机器阶段之后。** 它不接触机器，但它的行属于同一个结论。
- **`docker`、`docker-after` 与 `release` 不具破坏性**：D1 在 docker 存储（`@docker`，挂在
  `/opt/docker`）里保留两个镜像、一个容器、一个提交镜像和一个命名卷，日志写在 `/tmp` 下，
  不写槽位、不写 ESP 条目、不写启动决定。它们都不切换槽位、不重启，因此无需 `--yes`。

`power-cut` 按启动路径写它们的方式写下启动路径要读的两个文件——候选标记与中断记录——然后
重启。那是注入的状态，不是拔掉电源，证据里也这么写；它证明的是决策逻辑与启动接线，而那正是
缺陷所在。

结论有三个取值，`GAP` 不是通过：单行 `FAIL` 就让整次运行 `FAIL`；没有 `FAIL` 但有至少一个
`GAP` 就是 `GAP`；否则 `PASS`。来自挂掉的镜像站或不可达版本的 `GAP` 不会被转成 `FAIL`：
网络故障不是这个产品的缺陷。

## 红线

一次安装写的是机器**没有**在运行的那个槽位。除非正在运行的槽位是已提交槽位且没有排队的候选，
驱动拒绝安装；在任何时刻只要没有已提交的健康槽位可回退，它中止整次运行（`exit 3`）。破坏性
用例排在可逆用例之后，失败的用例被记录并搁置：恢复路径是 `ab-slot`，而不是手改
`ab/state.json`。

完全回不来的机器没有自动恢复。`image-install` 产物就是为此存在：刷它，重新开始。

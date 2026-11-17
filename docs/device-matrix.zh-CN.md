# 真机矩阵执行

`scripts/device/` 通过 SSH 驱动一台真机，把一次升级、降级或重启变成一行 PASS/FAIL/GAP。
它存在的原因是：一个槽「能启动」不等于「没坏」——只有状态字段、breadcrumb 与存活的数据
标记三者同时成立，才能回答「这次跳变之后机器还能用」。

## 矩阵只能用哪条线的版本

一句话：25.x / apk 线。低于 25 的版本以及任何 opkg 时代的树都会被拒绝，因为两个时代不共用包管理器、
防火墙模型和内核模块布局——`scripts/ci/upstream-watch.sh` 早就拒绝把 pin 定在 major 25 以下，
矩阵受同一条规则约束。`matrix.sh` 会读 payload 的 `platform-release`，对不合规的 payload 打一行明确
说明后拒绝，而不是让它跑起来、然后在某个看起来像产品 bug 的地方失败。24.x / opkg 线不在本项目范围内：
这里既不测试也不支持。

## 用途

A/B 模型只能由**真实上游版本**证明，改 manifest 里的版本号证明不了。矩阵因此在 CI
真实能构建的版本之间跳变（见 [`ci-pipeline.zh-CN.md`](ci-pipeline.zh-CN.md) 的
「构建非 pin 版本」），并在每次跳变后断言同一组不变量：

- `boot=ok` **且** `esp=ok` —— ESP 读不干净的启动不算通过；
- `generation` 严格递增、`pending=none`；
- 两个槽的 upper 都存在，且没有被引用的 `@overlay-*` 残留；
- 共享分区上的用户标记与 `/etc/config` 里的配置标记仍在；
- 启动日志里有 `stage=healthcheck-done result=ok` 与 commit 行。

最后一项最容易读错：本次启动的 mark 在轮转后位于 `boot-1.log`，所以驱动先看
`boot-0.log`，再看 `boot-1.log`，最后看 `ab-slot log --prev`，并记录是哪一份文件命中的。

## 怎么跑

```sh
scripts/device/matrix.sh --dry-run                    # 只打印计划，不动设备
scripts/device/matrix.sh --case M3 --payload-dir <dir>
scripts/device/matrix.sh --payload-dir <dir> --resume  # 跳过已 PASS 的用例

scripts/device/full-test.sh --dry-run --task <id> --expect 0.0.12   # 全套，只出计划
scripts/device/full-test.sh --yes --task <id> --expect 0.0.12 --payload-dir <dir>
```

`--payload-dir` 里放 `payload-<version>.tar`。结果按
`case<TAB>verdict<TAB>evidence<TAB>note` 追加到 `--results`，一条用例一行；中断后的续跑
靠读这个文件，不靠记忆。

环境取自 `AB_HOST`（默认 `root@192.168.2.49`）与 `AB_KEY`。ssh 固定带
`ControlMaster=no`、`ControlPath=none` 与忽略 `known_hosts`：重刷过的机器会换主机密钥，
而跑驱动的沙箱没有可写的 `~/.ssh`。

## 用户场景

`scenarios.sh` 回答的是另一个问题：用户装过软件、写过数据、改过设置之后，跨版本跳变还能不能保住这些，
装过的软件还能不能用。

| 用例 | 造什么 | 判什么 |
|---|---|---|
| S1 预装 | 从该版本自己的 apk 索引里装 luci 应用、一个 CLI 工具、一个 kmod | 已装版本快照、索引里没有的包，以及「装→跑一次→卸」这一圈之后不留残余文件 |
| S2 用户态 | `/data` 下的文件与目录树、两个假 docker tar、自定义 `uci` 段、hostname、时区、一条防火墙规则 | 每个文件的 sha256、目录条目数、每项设置的 `uci get`，以及真实 `network reload` 之后 ssh 仍应答 |
| S3 / S4 跳变 | 低→高、高→低，带着预装软件 | 每跳之后同一组数据/配置/软件/挂载/服务判定，并且落点必须是 `packages=aligned packages_reason=none`——`limited` 会带上对齐器记录的原因，这是判定项而不是报告项 |
| S5 账本 | 最终内核 | 哪些包仍有效、哪个 kmod 需重装、平台层自报什么 |
| S6 引导工具 | 不造，只读 | ESP 上 `vmlinuz-<slot>`/`initrd-<slot>` 与 payload 的 `kernel.bin`/`initramfs.cpio.gz` 逐字节一致；平台层工具与 `platform.tar` 一致 |
| S7 releasefeeds | 每个版本从它自己 release 的 feed 列表装一个包，然后跳变 | 每个版本确实从自己的 feed 装、diff 表点出动了什么，以及「feed 供不上某个包」被记为 feed 问题（GAP）而不是机器坏了 |
| S8 坏配置 | 故意写四类坏配置：指定不存在设备的 network 段、`fw4` 翻译不出来的防火墙规则、被截断的 `docker` `daemon.json`、返回 404 的 apk feed | 每一类要么被拒绝、要么机器可见降级后**恢复**；写之前该类的备份已落在 `/data`、事后逐字节还原；第二次 `apk update` 仍能区分「feed 关了」和「机器没网」。每类的证人是**坏东西没被采纳**，而不是退出码：`fw4 check` 对非法 section 是警告并跳过、仍然退 0（fail-safe，实测），`procd` 会在坏 `daemon.json` 之后重拉 `dockerd`，所以活着 pid 不能当证人——那里的证人是带重试的 `docker info` |

两条让这些用例可信的规则：

- **不用旧格式判定**：包名取自该版本自己的 apk 索引，配置只在出厂文件上做最小追加——市面上流传的
  23/24 时代片段描述的是 opkg 与另一套防火墙模型。
- **机器自己留退路**：S2 在 reload 之前用 `setsid`（镜像没有时用 `start-stop-daemon -b`）排好自还原，
  以 `/tmp/ab-scen-net.ok` 取消；两者都排不上的机器根本不 reload，被跳过的那半段记 FINDING，
  而不是记一条"没看就通过"。

ABI 只报告不判定：换了内核后 kmod 不匹配在 apk 世界是正常行为，因此记成 `FINDING:` 并附重装清单，
不单独改变任何 verdict。

## 社区软件样本（第二轮）

第一轮证明的是「机器上只有验收套件自己装的五个包」时的 A/B 事务。真实机器不是那样：用户会装 LuCI 主题、
软件站、代理类应用，还会改这些应用自己的 `/etc/config`。第二轮把这层装上再跳版本，回答一个问题——
事务是否仍然 commit，样本是否保住自己的配置。

- `scripts/device/software-probe.sh` 安装 `tests/fixtures/software-samples.json` 里列的样本
  （`--manifest` 换清单，`--sample` 只跑一个）。每个样本一行：装上就记 PASS 与落到的版本，
  装不上记 GAP 并给出原因与重跑命令——第三方源挂了、或内核模块 ABI 与本机不符，都算 GAP，永远不算 PASS。
- `--baseline <tag>` 在跳版本前记录、`--compare <tag>` 在跳版本后比对样本**自己的配置**（取值而不只是文件哈希），
  用的是其它驱动同一套快照助手。配置漂移会写进证据：它是本轮的发现，不是把已 commit 的一跳判红的理由。
- `--cleanup` 移除样本、它们的配置与加进去的源，机器回到产品基线。第三方源只写在设备侧
  `/etc/apk/repositories.d/`，**不**进镜像、不进 payload、也不改 `scripts/ci/net-defaults.conf.in`。
- `scripts/device/badconfig-probe.sh` 写一份「人真的能写出来」的坏配置（坏的 `daemon.json`、坏的 UCI 段、
  fw4 只警告的防火墙规则、假订阅地址），并且分开判两件事：谁拒绝了它／谁恢复了它，以及有没有别的东西被连累。

两条限制先说清，不等跑完才发现：样本清单**只用 25.x**，24.x 是 opkg，结论不可迁移；样本是测试夹具，
不是产品内容——仓库里没有任何东西依赖它们，装不装样本，发布资产的字节完全一样。

## 全套验收：一个顺序、一个结论

`full-test.sh` 把上面这些驱动，加上两个各自只回答一个问题的新驱动
（`docker-probe.sh`、`release-verify.sh`），按一个固定顺序跑一遍，并把每个相位的
结果文件折算成一个结论：

| 相位 | 回答什么 | `--only` 用例 |
|---|---|---|
| preflight | 密钥文件、ssh 可达、平台身份、剩余空间、payload 目录 | 永远执行 |
| probes | 一台还没人动过的机器的基线 | `grow network wan22 key platform adapter initrd packages` |
| feed-install | ac-12 / ac-13 / ac-3：feed 里有候选、机器确实吃下去了（默认 `--case all`：check→pin→install） | `ac-12`/`check`、`ac-13`/`install`、`ac-3`/`pin`、`both`、`all` |
| matrix | M1..M7：跳变之后机器还能不能启动 | `M1`..`M7` |
| scenarios | S1..S8：用户的数据与软件能不能扛过去 | `S1`..`S8` |
| docker | D1：真实 docker 负载的基线（经国内镜像站拉 ≥2 镜像、一个容器、一个命名卷、一个 commit 镜像） | `D1` |
| package-revert | P1..P4：包快照、离线回退、payload 篡改被拒、跨 base 的记录被拒。`U1`（包升级真的前进）默认不在集内——它会装包 | `P1`..`P4`、`U1` |
| recovery | 坏版本自己回滚 | `R1`..、`B1`.. |
| power-cut | 被打断的候选启动不会被无限重试 | `I1`、`I2` |
| docker-after | D2 / D3：镜像与产物跨跳存活、`@docker`/`@data` 子卷身份不变 | `D2`、`D3` |
| release | ac-1：已发布 release 的 tag、四个资产、SHA256SUMS 与 index.txt | `release`，或它的某个子句名 `verdict`/`sums`/`index`——任何一个都会选中整个相位，因为 release-verify.sh 每次都检查全部子句 |
| audit | PRD 里每个 ac 都有以它自己的名字登记的 evidence | 永远执行 |

这个顺序是依赖顺序，每一步的理由都写在这里，免得后来的人把它「改回」驱动名的字母序：

- **`feed-install` 排在 `matrix` / `scenarios` 之前。** ac-12 / ac-13 与 pin 用例都要求机器
  **低于**候选版本：feed 必须提供比当前更新的东西。matrix 与 scenarios 会把机器升到最新，
  所以把它们排在前面之后，feed-install 在一台完全健康的机器上也会按定义失败。
- **`docker` 拆成版本跳之前与之后两段，但仍然是同一个脚本。** D1 在 matrix 与 scenarios **之前**取基线，
  因为这两个相位就是这份基线要活过去的跳：机器已经在最新版本上时没有可跳的目标，D2 只能答「没有跳」
  而不是「存储活过了一次跳」（那种答案是带 `reason=no-jump` 的 GAP，绝不是 PASS）。D2/D3 在跳之后
  立刻判同一份存储。两段指向同一个 `<results>/docker-snapshots` 目录：D1 写 `before.snapshot`，
  docker-after 读回来并写 `after.snapshot`。之所以不拆成两个脚本，是因为采集与比较在跳的两侧必须是
  同一份代码；两段只差 `--case`（前段 `D1`，后段 `D2`/`D3`）。
- **`release` 排在机器相位之后、`audit` 之前。** 它完全不碰机器，但它的行属于同一个结论。
- **`audit` 最后，因为它判的是上面所有相位刚写下的记录**，而且要被告知这份记录属于哪一轮
  （`--task <id>`，或 `AB_TASK_ID`）。两者都没有时它记一行 GAP 并写明缺什么：它绝不会退回
  上一轮的任务号——关于旧记录的一张全绿表，读起来和关于本轮的全绿表一模一样。任务号查不到
  记录（没有 PRD，或 PRD 里没有 ac 条目）同样是 GAP：那是记录不完整，本轮机器根本没被判定，
  和「机器坏了」不是同一个结论。

`docker`、`docker-after`、`release` **不是**破坏性相位：D1 把两个镜像、一个容器、一个 commit 镜像与
一个命名卷留在 docker 存储（`@docker`，挂在 `/opt/docker`）里，另在 `/tmp` 下留日志，不写任何槽、
不写 ESP、不做任何启动决策；D2/D3 只读；`release-verify.sh` 压根不连机器。三者都不换槽、
不重启，因此不需要 `--yes`。

`power-cut` 是值得多读一遍的那个相位：它按启动路径自己写入的形式，写那两个文件——候选标记与
中断记录——然后重启。**这是注入态，不是拉电**，证据里也是这么写的；它证明的是决策逻辑与启动
接线，而那正是缺陷所在。

结论只有三种取值，`GAP` 不算通过：只要有一行 `FAIL` 整轮就是 `FAIL`；没有 `FAIL` 但有至少一行
`GAP` 就是 `GAP`；两者都没有才是 `PASS`。网络类 `GAP`（镜像站挂了、release 取不到——即 `docker`、
`docker-after`、`release`）**不会**把整轮判成 `FAIL`：PRD 风险 3 说网络故障不是本产品的缺陷。

## 红线

安装写的是机器**没有在跑**的那个槽。驱动只在「运行槽 = committed 槽且没有排队候选」时
才允许安装；任何时刻发现「没有可回退的 committed 健康槽」就中止整轮（`exit 3`）。
破坏性用例排在可逆用例之后；失败的用例只记录、不夹带修——恢复路径是 `ab-slot`，不是手改
`ab/state.json`。

机器彻底起不来时没有自动恢复。这正是 `image-install` 产物存在的意义：刷回去，重来一次。

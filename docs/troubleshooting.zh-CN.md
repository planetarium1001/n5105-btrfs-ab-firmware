# 故障排查

**中文** | [English](troubleshooting.md)

机器出问题时先读什么、每种现象通常意味着什么，以及本项目决定不去改变的行为。动手之前先读
日志：每个阶段都写 `key=value` 行，每个失败都带一个 `reason=` token，构建也报同一个
token，因此机器与构建可以不必猜着比对。

前置条件：机器上的 `root` shell，或把磁盘接到另一台 Linux 上。下面除特别说明外都是只读命令。

## 先读这些

```sh
ab-slot status                    # 一行机器可读，人读的句子走 stderr
ab-slot log                       # 本次启动
ab-slot log --prev                # 上一次启动
ab-slot log --upgrade             # 升级自身的输出（如果被保存过）
cat /boot/ab/state.json           # 槽位状态，即事实
cat /boot/ab/packages             # 软件包记录
```

`ab-slot status` 打印一行 `field=value` token，摘要走 stderr，所以
`ab-slot status 2>/dev/null` 只剩那一行。字段说明见 [update.md](update.md#field-reference)；
当没有任何记录时，`boot=`、`esp=` 与 `packages=` 读作 `unknown`，而不是一个让人安心的默认值。

## 启动与槽位问题

| 现象 | 通常意味着 | 怎么做 |
|---|---|---|
| 完全没有控制台输出 | 启动模式或磁盘不对 | 只用 UEFI 启动；检查磁盘顺序 |
| `p4=ok` 但没有 `stage=commit` | 健康检查失败 | `ab-slot log` 点名失败的探针；`ab-slot abandon` 清除待定槽位 |
| 升级后机器重启回旧槽位 | 新槽位健康检查失败 | 日志里有 `stage=abandon result=fail reason=healthcheck-failed detail=<probe>`；修好 payload 再装一次 |
| 机器反复回到已提交槽位 | 候选在用户空间之前就失败 | 日志里有 `action=fail-safe-abandon`；此时已无待定槽位，原因修好后重新安装 |
| `next=` 不是你以为的槽位 | 启动提示过时或没写 | `ab-slot next --write` 从 `ab/state.json` 重写；日志里 `stage=slot-cfg` 显示写了什么 |
| `disk=unknown` | 识别不出启动盘 | 日志里 `stage=device` 点名失败的那一级；检查 GPT 名字与 `ab/device.json` |
| `p4=degraded` | 共享分区挂不上，可写层在 tmpfs 里 | 本次启动之后的写入不会存活到重启；`ab-upgrade` 以 `writable-layer-degraded` 拒绝。当作硬件警告：从 live 系统用 `btrfs check` 检查磁盘并重装 |
| `state is locked by another process` | 写者持锁时死掉、ESP 无法写，或还有活着的写者 | 死掉的持有者会被接管（`stage=lock action=stale-lock-taken`）；活着的会被等待最多 `AB_LOCK_WAIT_SECS`（默认 1 秒）后拒绝。若锁目录建不出来（`cannot create /boot/ab/.lock`），说明 ESP 只读或已满：先把日志拷出来，再从另一个系统对 ESP 执行 `fsck.fat -a`——绝不要在正在运行的镜像里做 |
| `stage=resize result=fail:btrfs-resize` | 文件系统扩不了 | `ab/log/resize.log` 里有 btrfs 自己的消息；分区保持原大小，下次启动重试 |
| 日志里缺 `btrfs=ok` | 平台层丢了工具 | 从镜像重装；该工具随平台层发布 |

刷写后的首次启动在 p4 需要扩容时是两次启动：第一次写分区表并重启，第二次调整文件系统大小。
看到两次 GRUB 是设计在正常工作，不是失败。记录在 `<p4 根子卷>/.ab/grow`，
`stage=grow result=done`（或 `stage=resize result=ok`）是通过条件。

## 网络问题

| 现象 | 通常意味着 | 怎么做 |
|---|---|---|
| 首启后任何端口都没有地址 | 种子没跑，或失败了 | `ab-slot log \| grep net-seed`：`result=fail reason=<token>` 点名坏在哪一步；`result=skip reason=seeded` 说明已有配置 |
| 刚写完的盘上出现 `result=skip reason=seeded` | 可写层不是空的 | 文件就是事实：读 `uci show network`，判断那是不是你想要的配置 |
| LAN 地址不是 `192.168.100.1` | 之前配置过，或手工改过 | 默认值只在生成配置文件的那次启动应用；用 `uci` 按 [network.md](network.md) 设置地址 |
| WAN 设备没有租约 | 没插线、上游没有 DHCP，或地址已被占用 | 对 `uci get network.wan.device` 点名的设备跑 `ip -brief address`，再看上游路由器的客户端列表 |
| `uci show firewall` 里有 `allow_ssh_wan`，但 `nft list ruleset` 里没有 | 规则加入后规则集还没渲染 | `/etc/init.d/firewall reload`，再看一次 |
| 便利镜像上规则存在但 WAN 侧 SSH 被拒 | `dropbear` 绑定了某个接口 | `uci show dropbear` 必须没有 `Interface`；删掉并提交 |
| 默认镜像上 WAN 侧 SSH 超时 | 那个镜像按设计没有 WAN 规则 | 走 LAN 或控制台，或刷 `-wan-ssh` 镜像 |
| `stage=net-seed result=lan-only` | 机器只有一个网口 | 预期行为：没有第二个网络可路由 |

种子失败时启动仍会完成，原因留在控制台上。不等修复就想进去，可以手工给一个端口配地址——
它不会活过重启，这正是重点：

```sh
ip link set eth1 up
ip addr add 192.168.100.1/24 dev eth1
```

把笔记本插到同一个网口，设成 `192.168.100.2/24`，访问 `192.168.100.1`。手工写
`/etc/config/network` 会永久结束种子的工作：文件从此存在，之后任何启动都不会再碰它。

## 升级与软件包问题

| 现象 | 先跑的命令 | 它告诉你什么 |
|---|---|---|
| 升级以 `74` 退出 | 打印出的 `reason=` 行，其次 `ab-slot log --upgrade` | 哪项检查拒绝，以及什么都没写 |
| `follow=` 一直是 `pending` | `ab-packages status` 与 `ab-slot log \| grep stage=packages-refresh` | 重试到哪一级、探针结论与上次尝试的原因 |
| `follow=failed` | `ab-packages status`，然后 `ab-packages update` | 原因 token；`apk-<rc>` 说明事务本身失败 |
| `packages=limited` | `cat /boot/ab/packages` | 对齐器的 token；下次升级会重写元数据 |
| `packages_reason=` 是 `other-slot`，或某个包字段是 `unknown` | `ab-slot status` 与 `cat /boot/ab/packages` | 记录描述的是另一个槽位，或没有槽位；下次升级或回滚会重新指向 |
| 可写分区写满 | `df -h /mnt/p4` 与 `ab-slot gc --dry-run` | 哪些层已无引用、会被回收 |

软件包事务与系统升级刻意分开：`apk` 写进可写层，系统升级替换一个槽位。先做系统升级，再做
软件包升级。除非 `ab-slot status` 报告 `packages=aligned` 或 `packages=followed`，
`ab-slot packages upgrade` 会拒绝，因为在过时的 pin 后面升级软件包会装上与当前内核不匹配的
模块。

## dropbear 2025.89 上的交互式 SSH

`ssh -tt <host> '<command>' </dev/null`——看起来是交互式会话，但 stdin 已经到文件末尾——
在健康的机器上会失败。客户端立刻被断开，服务端记下三行 pty 错误：

```
dropbear[31119]: ioctl(TIOCSCTTY): I/O error
dropbear[31119]: /dev/pts/0: No such file or directory
dropbear[31119]: open /dev/tty failed - could not set controlling tty: No such device or address
```

机器和 `/dev` 都没有问题：人在终端前登录，或任何 stdin 保持打开的客户端，都能登录并拿到提示
符。镜像带的是 dropbear v2025.89，自上游提交 `e28ba1b`（2024.85）起，dropbear 在通道**任一**
方向结束时就会关闭 pty 主端。stdin 已在 EOF 时写方向立刻结束，pty 被销毁，子进程的
`setsid()`/`TIOCSCTTY` 面对的是一个已不存在的 tty。上游报告：
[mkj/dropbear#365](https://github.com/mkj/dropbear/issues/365)，仍未关闭。

| 客户端 | stdin | 结果 |
|---|---|---|
| `ssh -tt host '<cmd>' < /dev/null` | 已在 EOF | **失败**，三行错误 |
| `ssh -tt host '<cmd>' < <(sleep 12)` | 打开、无数据 | 可用 |
| `printf 'echo X\n' \| ssh -tt host '<cmd>'` | 一行，然后 EOF | 可用：shell 在 EOF 到达前已拿到 pty |
| `ssh -tt host`（登录 shell）`< <(sleep 25)` | 打开 | 可用 |
| `ssh host '<cmd>'`（无 pty） | 任意 | 可用，但证明不了 pty |

触发条件是客户端的一个属性：通道打开时 stdin 是否已经到 EOF。问"能否交互式登录"的探针必须
在会话期间保持 stdin 打开：

```sh
# 一个 keeper 进程保持 stdin 打开且不写任何数据
ssh -tt -i <key> root@<host> 'readlink /proc/$$/fd/0' < <(sleep 8)

# 不用进程替换的等价写法，适用于 POSIX sh
sleep 8 | ssh -tt -i <key> root@<host> 'readlink /proc/$$/fd/0'

# 登录 shell，不带远端命令；输出必须以提示符结尾
sleep 8 | ssh -tt -i <key> root@<host>
```

本项目不修它：打 dropbear 补丁意味着每次 dropbear 升级都要带着补丁走，而换成 OpenSSH 意味着
多一个守护进程、多一套认证故事，而这个镜像的重点是"上游加 A/B"。若这个取舍改变，三条出路
是：装 OpenSSH、给 dropbear 打补丁、等上游修复。

## 只有跟随能跑时软件包才会跟随 base

升级替换系统树；软件包住在可写层里，保持安装时的版本。从 0.0.13 起，它们在 base 切换后由
自己的事务（对整个 world 做一次 `apk upgrade`）搬到新 base，因此搬不动的软件包不会回滚一次
已通过检查的系统升级。这仍不覆盖：

- **没有网络也没有预取。** 跟随需要包体。如果预取没能跑、且首启时机器离线，记录会说
  `follow=pending reason=network`；网络回退会重试一天（之后 `follow=abandoned`），
  `ab-packages update` 可按需重试。没有别的东西会搬动它们。
- **没有留存包体的本地包。** 从 `.apk` 文件装的包没有源，apk 也不留副本（`/var` 是 tmpfs）。
  它在计划块里是 `NO COPY`，在记录里是 `skipped=local:<name>`，会一直保持原版本，直到有人用
  `ab-packages replay <file>` 留下包体。
- **为另一个内核构建的包体。** 它不能重放到内核不同的 base 上，因为它带的模块加载不了。它是
  `ABI STALE`，保持旧版本。
- **上游已下架的包。** 它靠已有文件继续工作，只有它自己的启动过程会暴露问题，`world` 条目
  会被移除，下次升级不再尝试。
- **预测可能不准。** 计划块是对暂存副本跑 `apk --simulate` 渲染的，feed 可能在提问与启动之间
  变化。记录才是事实；块承诺 39 个而记录说 37 个，不是矛盾，而是预测与实测。

## apk 说数据库被锁定

现象：升级后的头几分钟里执行 `apk add`、`apk del` 或 `apk update`，得到：

```
ERROR: Unable to lock database: Resource temporarily unavailable
ERROR: Failed to open apk database: Resource temporarily unavailable
```

原因：新 base 的首启用一次覆盖整个 world 的 `apk upgrade` 把已安装的包搬过去，跑在后台
worker 里。这个事务在整段运行期间持有 apk 数据库锁——参考机器上是 168 个包——因此在这个窗口
里启动的任何其他 apk 事务都打不开数据库。没有包损坏，也没有东西丢失：worker 结束后同一条命令
即可正常执行。

处理：

- 等 worker 结束，再执行一次命令。
- `ab-slot status` 报告状态：`packages=aligned`（包还没搬）、`packages=followed`（已经在新 base
  上）或 `packages=limited`（元数据不全，`packages_reason=` 说明原因）。`follow=pending` 表示
  搬动仍待执行，`follow=followed` 表示已完成，`follow=never` 表示没有需要搬的，`follow=failed` 或
  `follow=abandoned` 表示没有跑成；`ab-packages update` 可按需重试。
- `ab-slot log` 每次尝试留一行 `stage=packages-refresh slot=<a|b> result=<state>
  reason=<token> version=<base>`，`ps w | grep apk` 显示持有锁的事务。
- worker 自己的输出在 `/tmp/ab-packages-follow.log`。

不要：

- 删除 `/lib/apk/db/lock`——这把锁的作用就是不让两个事务同时改写同一个数据库，写坏的数据库
  比等待更糟；
- 杀掉持有锁的 apk 进程——同样会留下写坏的数据库，而且是在一台本来还能用的机器上；
- 用强制参数把事务推过锁。

## 新 base 的首启可能让服务留在停止状态

升级后的首次启动会搬动软件包集合，procd 就在这个窗口里启动引导脚本。在内核模块正被替换时
初始化的守护进程可能失败，而 procd 只启动服务一次：`dockerd` 的 init 脚本没有设
`procd_set_param respawn`，所以那次启动里没有任何东西重试它。等更久也没用，因为实例从未被
respawn。

机器现在的做法：跟随安定之后，**完成跟随的那条路径**向 procd 询问它启动过又丢失了哪些服务，
并各给一次新的启动。两条路径都做——分离的首启 worker，以及把首启因缺网络而推迟的跟随真正完成
的那个网络接口事件。环形日志记录
`stage=services-reconciled slot=<a|b> result=ok started=<n> failed=none down=<names>`；
`result=partial` 点名脚本自己拒绝的服务，`result=skipped
reason=follow-unsettled|boot-not-settled|no-procd-query` 说明没有尝试修复，
`reason=already-reconciled` 说明本次启动已经修复过一遍。判据是 procd 的
实例记录——实例存在、未运行且以非零退出——而不是"已启用但没在跑"：一次健康的启动有七个这类
服务（一次性脚本、按需重放状态的程序、被禁用的守护进程），它们绝不能被启动。

它不覆盖：procd 接受之后又死掉的守护进程，以及配置本身就是它停止原因的守护进程。这样的启动
之后服务仍然停着，就把机器重启一次。

## 配置文件与 `*.apk-new`

apk 会保护它发现被改过的配置文件：用户的文件保留自己的字节，软件包自带的那份写在旁边，名为
`<file>.apk-new`。那不是合并。本项目没有任何东西读取、合并或删除它，而机器自行选择的合并，
正是防火墙规则或网络接口在无人编辑的情况下消失的方式。

```sh
find /etc/config -name '*.apk-new'        # 等待决定的文件
apk audit --backup /etc/config            # apk 数据库认为不同的文件
```

从 0.0.13 起计划块会统计它不会覆盖的文件（`Config: N files differ from their package`），
因此这个决定的规模在升级之前就可见。

## 历史软件包 feed 与内核 ABI

官方镜像站保留每个已发布版本的 release 目录，因此分步升级或降级仍能点名更早的版本。内核不会
跟着走：kmod feed 按内核段归档，而段随每次内核升级变化。

| 版本 | kmods 段 | `kmod-usb-storage` | 用户空间索引 |
|---|---|---|---|
| 25.12.0 | `6.12.87` | `6.12.87-r1` | 与 25.12.2 相同字节 |
| 25.12.1 | `6.12.94` | `6.12.94-r1` | 与 25.12.2 相同字节 |
| 25.12.2 | `6.12.103` | `6.12.103-r1` | 与 25.12.0 相同字节 |

因此取自旧版本的 feed 行会提供用户空间软件包，却一个 kmod 都没有：`htop` 在那个版本的索引
里，`kmod-usb-storage` 不在，而当前内核段的 kmod 目录在该版本下返回 404。对齐器会把
`distfeeds.list` 与 `repositories.d/*.list` 里每个 `/releases/<x>/` 和 `/kmods/<segment>/`
改写成槽位当前运行的版本；若 feed 仍点名另一个版本，跟随记录会是
`packages=limited packages_reason=feeds-stale`。

绕法：把历史 feed 放进 `/etc/apk/repositories.d/customfeeds.list`——对齐器与跟随的 feed 探针
都会跳过该文件——按段取 kmod，当某个段不再被提供时，把它的索引、`.sig` 与 apk 镜像到本地
HTTPS feed 并让 `customfeeds.list` 指向它（[update.md](update.md#build-your-own-feed)）。
`ab-packages sources <name>` 会给出提供某个包的源及完整 URL。

## 目标版本不发布的软件包

版本之间移动可能让 `world` 文件点名一个目标版本从未构建过的包，而这样一个名字会让之后每次
apk 事务都无法求解。跟随会在事务运行前把这个名字从 `world` 里丢掉；不会卸载任何东西，不会
碰任何配置，也不涉及 `/data`。

两道闸门会拦住这个剪枝：对任何名字都答不出来的索引，不能作为该版本什么都不提供的证据
（`index-unusable`）；索引刷新失败的调用方会明说（`index-stale`）。这两种情况下都不会丢任何
东西。版本已消失的 pin 会被保留，因为索引仍然提供这个名字。

## 属于正常行为、不是故障

- **单网口机器不是路由器。** 种子把它降级为仅 LAN：该网口加入 `br-lan`，`wan` 被移除，
  `wan-present` 探针每次启动都失败，因此槽位不提交。LAN 侧正常工作。
- **网口名字是内核的，不是面板丝印的。** `eth0` 到 `eth3` 不必与机箱标签对应，镜像里也没有
  任何东西去猜硬件。每台机器记录一次映射（[install.md](install.md)）。
- **默认值只应用一次。** 它们属于生成网络配置的那次启动；升级会带上可写层且从不重新应用，
  因此改过的默认值只会到达重新刷写的机器。
- **便利镜像在 WAN 侧打开 `22/tcp`，没有东西替你关。** 只有
  `n5105-ab-<upstream>-install-wan-ssh.img.gz` 带 `allow_ssh_wan`，且那里的 `dropbear` 接受
  密码认证，密码就是镜像带的那个 root 密码。
- **0.0.7 之前写下的镜像没有首启网络。** 它们在任何端口上都没有地址，唯一入口是控制台。
  重刷，而不是给旧镜像打补丁。
- **台架机器可能整段开放 WAN zone。** 那是调试状态（`scripts/device/wan-open.sh`），不是发布
  行为；发布镜像保持 WAN 输入 `REJECT`，`-wan-ssh` 变体只开 `22`。

## 报告之前要收集什么

把日志收集到两个槽位共享的磁盘上，等 LAN 侧通了再拷出来：

```sh
mkdir -p /data/evidence
{
    date
    ab-slot status
    ab-slot log
    ab-slot log --prev
    uci show network
    uci show firewall
    uci show dropbear
    ip -brief address
    ip -brief link
    nft list ruleset
    btrfs subvolume list /mnt/p4
} >/data/evidence/first-boot.log 2>&1
```

完全够不到机器时，挂载 ESP（`PARTNAME ab-esp`，FAT）读 `ab/net.json`（种子做了什么决定、看到
了哪些网口）、`ab/log/boot-0.log`（正在运行那次启动的环形日志）与 `ab/log/resize.log`
（首启扩容）。这三个文件不需要启动、不需要 SSH、也不需要控制台。

有用的报告包含：`sha256sum -c SHA256SUMS` 的记录，首启的照片或串口抓取（含 `stage=net-seed`
行），改动前后的 `ab-slot status`，填好的网口映射表，以及每个失败的原样输出与其 `reason=`
token。

## 限制

- `ab-slot log` 只保留三次启动。更早的证据已经没了；重启之前先收集。
- 环形日志每个文件在 32 KiB 处截断，并留下 `TRUNCATED=1` 标记。
- 回滚深度为一层：回滚回到上一个槽位，而不是回到磁盘上已不存在的更早版本。
- 镜像里没有任何东西能修 FAT 文件系统：损坏的 ESP 需要从另一个系统跑 `fsck.fat`。

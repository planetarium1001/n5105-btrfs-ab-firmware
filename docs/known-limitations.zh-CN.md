# 已知限制

[English](known-limitations.md) | **简体中文**

这里的「限制」是本项目**决定不改**的行为，连同说明「这是谁的问题」的取证。每条都写清：用户看到什么、
根因在哪、什么时候会发生什么时候不会、以及自动化探针必须怎么写才算在测机器而不是在测测量方法。

## dropbear 2025.89 上的交互式 SSH 登录

`ssh -tt <host> '<命令>' </dev/null`——一个长得像交互会话、但 stdin 已经处在文件末尾的调用——在一台
健康的机器上会失败：客户端立刻被断开，服务端打出三行 pty 报错：

```
dropbear[31119]: ioctl(TIOCSCTTY): I/O error
dropbear[31119]: /dev/pts/0: No such file or directory
dropbear[31119]: open /dev/tty failed - could not set controlling tty: No such device or address
```

机器没有任何问题，`/dev` 也没有任何问题。同一台机器、同一次启动里，人手终端（或任何 stdin 保持打开的
客户端）能登录并拿到 `root@ImmortalWrt:~#`。两句话都是 2026-11-17 在参考机上隔几分钟实测的。

这条记录之所以存在，是因为本项目上一轮把这三行读成了「我们 initramfs 里那套设备节点有缺陷」。
那个读法是错的，它让一整轮修复追了一个并不存在的根因。

## 根因：子进程拿到 pty 之前，master 已经被关掉

镜像里是 **dropbear v2025.89**（musl），来自 ImmortalWrt 25.12.2。上游提交 `e28ba1b`
（"Don't try to shutdown() a pty"，2023-12-09，自 2024.85 起发布）把 pty channel 在
`src/svr-chansession.c` 里改成 `channel->bidir_fd = 0`。带上这个标志后，`src/common-channel.c`
的 `close_chan_fd()` 会在 channel 的**任意一个方向**结束时立刻 `m_close()`。在此之前，同一处调用的是
`shutdown()`：对 pty 它只是返回 `ENOTSOCK`（无害），真正的 `close()` 等到读写两侧都结束才发生。

于是当客户端 stdin 已经 EOF 时，写方向立刻结束，dropbear 关掉 pty master；随后子进程才执行
`setsid()` 与 `TIOCSCTTY`，而它面对的是一个已经不存在的 tty——pty 主从对被摧毁在登录 shell 拿到它之前。

上游报告：[mkj/dropbear#365](https://github.com/mkj/dropbear/issues/365)，2025 年 5 月提出，至今 open；
dropbear master 分支里那一行 `bidir_fd = 0` 仍在。这个行为在别的工具上也早被发现过：
[mosh-devel，2013 年](https://mailman.mit.edu/pipermail/mosh-devel/2013-October/000637.html)
（「dropbear 不喜欢 `ssh -n -tt` / `ssh -tt </dev/null>`」）。

## 三行报错各自说的到底是什么

三条消息出自同一个函数 `pty_make_controlling_tty()`（`src/sshpty.c`），按这个顺序打印。在 Linux 6.12 里
每个 errno 都只有一个产生点，所以这三行合起来既能定位根因，也能排除掉其它候选：

| 消息 | 出处 | 这个 errno 只可能表示 |
|---|---|---|
| `ioctl(TIOCSCTTY): I/O error` | `sshpty.c:301` | `tiocsctty()` 自己只会返回 `EPERM`。`EIO` 来自 `hung_up_tty_ioctl()`：行规程已 halt 或 `f_op` 被换掉，即 **该 tty 已经 hang up** |
| `/dev/pts/0: No such file or directory` | `sshpty.c:327` | devpts 从设备的 `ENOENT` 由 `devpts_pty_kill()` 产生，而它只在 **master** 被释放（或 devpts 实例被移除）时运行 |
| `open /dev/tty failed - ... No such device or address` | `sshpty.c:333` | `ENXIO` 是「本进程没有控制终端」，是上面两条的**结果**，从来不是原因 |

由此得到两条硬结论：pty master 的最后一个 fd 在子进程能 `TIOCSCTTY` 之前就被关掉了；`/dev/tty`
这个节点本身是好的。

## 什么时候会发生，什么时候不会

同一台参考机、同一次启动、同一个下午实测：

| 客户端 | stdin | 结果 |
|---|---|---|
| `ssh -tt host '<命令>' < /dev/null` | 已经是 EOF | **失败**，三行报错 |
| `ssh -tt host '<命令>' < <(sleep 12)`（打开但无数据的管道） | 打开、无数据 | 成功：`fd0=/dev/pts/0`、`tty_nr=34816` |
| `printf 'echo X\n' \| ssh -tt host '<命令>'` | 一行数据后 EOF | 成功：EOF 到达前 shell 已经拿到 pty |
| `ssh -tt host`（登录 shell）`< <(sleep 25)` | 打开 | 成功：MOTD 加 `root@ImmortalWrt:~#` |
| `ssh host '<命令>'`（无 pty） | 任意 | 成功，但什么都不证明 pty |
| 人手终端、串口控制台 | 终端 | 成功 |

所以触发条件是**客户端**的一个属性：channel 建立时 stdin 是否已经 EOF。服务端的 `/dev`、`/dev/pts`、
devpts 挂载选项、`/dev/tty`、procd 的会话处理、A/B 布局都不参与。`ttyS0` 与 `tty1` 上的 `askfirst`
控制台从不关闭 stdin，不受影响。

## 什么不是原因

- **不是本项目 initramfs 里的 `/dev`。** 运行时的 `/dev` 属于 procd：它在 `/dev` 上新挂一层 `tmpfs`、
  按 `/sys/dev/{char,block}` 建节点、把 `devpts` 挂到 `/dev/pts`。initramfs 阶段造出来的东西之后不可见。
- **不是 devpts 的挂载选项。** 实测把 `/dev/pts` 重挂成 `mode=620,ptmxmode=666`：`</dev/null` 形态照样失败，
  保持 stdin 打开的形态照样成功。出厂的 `mode=600,ptmxmode=000` 就是上游 procd 传空选项时内核给的默认值。
- **不是 `/dev/ptmx`、`/dev/tty` 或 devpts 实例。** `/dev/ptmx` 是字符设备 5:2，`/dev/tty` 存在；从设备节点
  确实先出现在可见的 `/dev/pts` 里、然后被 unlink——这两步都能在设备上直接观察到。
- **不是 devpts 上的 `gid=5`，也不是缺 `tty` 组。** 这个镜像里从设备节点属于 `root`、mode 0622；
  这两个值都不决定成败。

## 主题是调试台包装的，不在镜像里

发布镜像刷完是 `bootstrap`：上游 rootfs 里没有 `luci-theme-argon`，也没有任何东西安装它。
argon（连同 `luci-app-argon-config` 与中文包）由 `scripts/device/bench-setup.sh` 装到正在
被观察的那台机器上，脚本会报 `theme_source=installed` 说明是它做的。

2026-11-18 定案：镜像保持上游默认。为了让界面好看而多发一个主题包，是为了非功能收益
去偏离上游，而且每次上游 rebase 都得跟着维护。

## 包只在跟随能跑的时候才跟上基底

升级替换的是系统树；用户装在上层的包仍留在可写层、保持安装时的版本。这是有意的取舍——在升级过程里
重新解析 world 会让「升级」本身变成最脆弱的一步——所以 0.0.13 起，包由自己的事务跟随，发生在换基底
之后（见 [update.zh-CN.md](update.zh-CN.md#包怎么跟随一个基底)）。那是对 world 的一次 `apk upgrade`，
判定来自它打印了什么，而且它可以失败而不影响刚启动的这个系统。

它仍然覆盖不到的情况：

* **既没有网络也没有预取。** 跟随需要本体。如果预取没跑成，而机器首次启动时离线（或卡在认证页后面），
  包就留在原地，记录写 `follow=pending reason=network`。网络兜底会重试一天（之后 `follow=abandoned`），
  `ab-packages update` 可以随时手动重试；除此之外没有别的东西会搬动它们，而机器其余部分完全可用。
* **没有留住本体的本地包。** 从 `.apk` 文件装上的包没有源，apk 也不留副本（`/var` 是 tmpfs；
  2026-11-18 实测：一台装着四个本地包的机器上 `find / -name '*.apk'` 什么都没有）。这种包在计划块里
  是 `NO COPY`，记录里是 `skipped=local:<name>`：它保持现有版本，直到有人把本体留住
  （`ab-packages replay <文件>`）。
* **为另一个内核构建的本体。** 依赖 `kernel=<hash>` 的本地包无法重放到另一个内核的基底上，重放会装上
  加载不了的模块。它是 `ABI STALE`，并以旧版本保持已装。
* **上游已经下架的包。** 它靠现有文件继续工作，只有它自己启动时才会暴露；`world` 条目会被摘掉，
  下一次升级不再试图跟随。矩阵在每次跨基底后判定 `tests/fixtures/follow-samples.json` 里的样本集，
  就是为了让这种情况在用户遇到之前被抓住。
* **预测可能不准。** 计划块是按暂存树上 `apk --simulate` 的结果渲染的，而从提问到启动之间 feed 可能
  已经变了。记录才是事实；计划块许诺 39 个包、记录说 37 个，这不是矛盾，而是一次预测和一次测量。

## 新基底的首次启动可能把某个守护进程留在 down 状态

升级后的首次启动会搬动整套包：实测有一次启动升级了 128 个包、保留了 138 个，第三轮矩阵实测是 168 和
97。procd 正在这个窗口里启动 boot 脚本，所以一个在内核模块正被替换时初始化的守护进程会失败，而本次 boot
内没有别的东西再试它。2026-11-19 受控跳变中 `dockerd` 自己说的话：

```
failed to start daemon: Error initializing network controller: error obtaining controller
instance: failed to register "bridge" driver: failed to add jump rules to ipv4 NAT table:
... Warning: Extension addrtype revision 0 not supported, missing kernel module?
```

它整个 boot 都 down 着。同一天更早在同一台机器上实测：`dockerd` 从 03:59Z 一直 down 到 05:20Z，跨 15 次
以上机器重启，而机器自己的记录写的是 client 在、daemon 不在。

为什么「等久一点」不管用：procd 只启动服务一次。`dockerd` 的 init 脚本没有设
`procd_set_param respawn`，所以 procd 从未重试它、从未记下 crash loop、也没有任何预算可耗尽。围着健康探针
加的重试循环够不到一个从未被 respawn 的实例——这正是本项目没有去放宽探针重试次数的原因。

机器现在的行为：首启的分离 worker 在包跟随落定、且 boot 已经走完自己的脚本之后，问 procd 它启动了哪些
服务又丢了哪些，然后对每一个各做一次新的 start。ring log 记录结果：

```
stage=services-reconciled slot=a result=ok started=1 failed=none down=dockerd
```

`result=partial` 配 `failed=<csv>` 表示服务被 start 了但它自己的脚本拒绝了；`result=skipped
reason=follow-unsettled|boot-not-settled|no-procd-query` 表示这次修复没有尝试，reason 说明缺的是
哪个事实。这一步按设计是 best-effort：它不决定跟随是否成功，也从不阻塞启动。

### 判据是 procd 的记录，不是「没在跑」

这次修复**刻意不**去启动所有「已 enable 但没在跑」的服务。参考机健康启动时有七个这样的服务，没有一个是
坏的：

| 服务 | procd 的记录 | 为什么不能启动它 |
|---|---|---|
| `system`、`ucitrack`、`gpio_switch` | 没有实例记录 | 已经跑完的一次性 boot 脚本 |
| `firewall`、`packet_steering` | 没有实例记录 | 按需重放状态，不是常驻守护进程 |
| `cron` | 没有实例记录 | `start_service` 提前返回：本机没有 crontab |
| `openclash` | 没有实例记录 | 机器自己的配置写着关 |
| `urandom_seed` | 有实例，`running=false`，`exit_code=0` | 它已经完成了自己的任务 |

按「已 enable 且没在跑」这条更宽的规则实现，会打乱 procd 的启动顺序重跑 boot 脚本、启动用户在配置里明确
关掉的服务、并在一台一切正常的机器上报 `result=partial`——把这个日志行唯一的价值毁掉。

实际使用的规则是 procd 自己的实例记录：实例存在、没在跑、且以非零退出。实测那次坏掉的 boot 里这个集合只有
`dockerd`（`running=false`、`exit_code=1`），别无其他。同一条规则也覆盖 procd 确实 respawn 到 crash
loop 的服务，因为那样的实例同样以非零结束。

它覆盖不到的情况：

* **procd 接受了、随后又自己死掉的守护进程**（在对账之后）。那时实例已经归 procd 管，ring log 只能说明
  第二次机会已经给过。
* **因为自身配置就是 down 的守护进程。** 那不是「丢掉的实例」，对账刻意不动它。
* **从未落定的跟随。** 什么都没被替换，所以也不需要这次修复。

如果这样一次启动之后某个守护进程仍然 down，重启机器一次。这条限制存在的意义是让那种情况变罕见，而不是
否认它；这也正是能证明差别的那个测量：重启清掉整个 boot，对账只清掉 procd 丢掉的那些服务。

## `*.apk-new` 没有人替你合并

apk 会保护它发现被改过的配置文件：用户的文件保持原样，包里的副本写在旁边成为 `<文件>.apk-new`。
正是这条性质让包跟随是安全的：`tests/modules/upgrade/test_local_assets.sh` 在一次重放前后断言它，
本板也实测过（`apk upgrade dnsmasq-full` 把改过的 `/etc/config/dhcp` 原样保留，并写出
`dhcp.apk-new`）。

但它不是合并。`*.apk-new` 是一份证据：这个包改了用户也改过的东西；本项目里没有任何东西读取、合并或
删除它，差异会静默地留在那里，直到有人去看。两种看法：

```sh
find /etc/config -name '*.apk-new'                    # 有多少在等人做决定
apk audit --backup /etc/config                        # apk 数据库说哪些文件有差异
```

决定为什么必须手动：机器自己选的合并，就是某条防火墙规则或某个网络接口在没有编辑过它的情况下消失的
方式。0.0.13 起，计划块会数出它不会覆盖的文件（`Config: N files differ from their package`），
所以这个决定的规模在升级之前就能看见，而不是之后。

## 调试台上 WAN 整个开放是有意的

在实验室网段里调试的机器，WAN zone 是完全开放的（`wan input ACCEPT`，见
`scripts/device/wan-open.sh`）。这是**调试台状态**，不是出厂行为，也不代表产品口径：
把"需要的那几个端口"逐个放行（22 给 `-wan-ssh` 变体、80 给网页界面、主题再要 443），
会把每一条漏放的规则都变成看起来像产品缺陷的故障——网页界面"打不开"，其实是它在用
`403` 回登录页。

发布镜像保持上游默认（WAN input `REJECT`），`-wan-ssh` 变体只开 22。
`scripts/device/wan-open.sh --restore` 会用驱动写在 `/root/firewall.before-open-wan.bak`
的备份还原并校验 sha256。

## 本项目为什么不在本地修它

故障在 dropbear 里，夹在「早关 stdin 的客户端」与「把任一方向结束当成 pty 结束的服务端」之间。两边都不是我们的，
而两条看起来可行的修法都会让镜像离上游更远：

- 给 dropbear 打补丁，意味着每次 dropbear 升级都要带着这个补丁走，而这个包本身还带着 OpenWrt 自己的补丁
  （含允许 root 空口令的那条）。
- 用 OpenSSH 换掉 dropbear，意味着第二个守护进程、第二套配置面、更大的镜像，以及一套不同的认证故事——
  而这个镜像的全部意义是「上游 + A/B」。

本项目的规则是：一处差异若不给设备所有者换来任何东西，就与上游保持一致。动手登录的所有者不受影响；
受影响的只有我们自己的探针。

**如果哪天这个取舍变了，三条出路**（每条都要单独立项，都不在本轮范围）：

1. **加装 OpenSSH**（`openssh-server`）专供交互会话，可与 dropbear 分端口并存。偏离最大：多一个包、
   多一套配置、两个守护进程要一起维护。
2. **给 dropbear 打补丁**：恢复 `shutdown()` 路径，或用 `TIOCGPTPEER` 之类手段把 master 的副本留到
   两个方向都结束。偏离较小，但每次 dropbear 升级都要重新验证，并且需要在上游观察里留一条。
3. **等上游修好**，随下一次 rebase 取得。要盯的就是 `mkj/dropbear#365`；
   上游的任何修复会先出现在 [daily-upstream-watch.md](daily-upstream-watch.md) 与
   `scripts/ci/upstream-watch.sh` 里。

## 探针必须怎么驱动一个交互会话

一个问「有没有东西能交互登录」的自动化探针，必须把客户端 stdin 在整个会话期间**保持打开**。与人的终端
等价、且仅与下面两种等价：

```sh
# 一个保持 stdin 打开、什么都不写的「看守」进程：实测过的形态
ssh -tt -i "$KEY" root@<host> 'readlink /proc/$$/fd/0' < <(sleep 8)

# 同样的东西，给 POSIX sh 用（没有进程替换）
sleep 8 | ssh -tt -i "$KEY" root@<host> 'readlink /proc/$$/fd/0'

# 登录 shell，不带远端命令；输出必须以提示符结尾
sleep 8 | ssh -tt -i "$KEY" root@<host>
```

在本仓库里，这个原语是 `scripts/device/lib.sh` 的 `dev_ssh_tty`，建在它上面的探针是
`scripts/device/login-probe.sh`：

```sh
scripts/device/login-probe.sh --hold 8        # probe=pty 与 probe=login，各一行
scripts/device/login-probe.sh --dry-run       # 只打印会发出去的调用
```

**近似的边界。** 看守管道证明的是：服务端能为一个不提前关闭 stdin 的客户端分配 pty、设上控制终端、
拉起登录 shell。它不证明人的击键比 hold 更快到达；它对终端尺寸、流控、作业控制一无所知；
它与物理控制台无关——控制台走 `askfirst` 与 `login.sh`，必须由人站在机器前面确认。

两个各自花掉一次测量的坑：

- pty 处在 cooked 模式，从设备会把 `\n` 翻成 `\r\n`。拿 `^tty_nr=[0-9]+$` 去匹配 pty 的原始输出会一条都
  匹配不上；先去掉 `\r`。
- 这个镜像的 busybox 没有 `tty` applet（实测 `command -v tty` 无输出），所以 `ssh -tt ... tty` 在一台
  完全健康的机器上会回 `ash: tty: not found`。请改用 `readlink /proc/$$/fd/0` 与
  `/proc/<pid>/stat` 的第 7 个字段（`tty_nr`）。

## 怎么复现

两条都是只读的；第二条才是探针该做的事。

```sh
K="-i .workflow/secrets/n5105-device-ssh-key -o StrictHostKeyChecking=no \
   -o UserKnownHostsFile=/dev/null -o ControlMaster=no -o ControlPath=none"

# 假阴性：客户端被断开，服务端打出那三行
ssh -tt $K root@192.168.2.49 'echo probe' </dev/null
ssh $K root@192.168.2.49 'logread | tail -n 5 | grep -i dropbear'

# 同一个问题，正确地问：pty、控制终端、提示符
sleep 8 | ssh -tt $K root@192.168.2.49 'readlink /proc/$$/fd/0; awk "{print \$7}" /proc/$$/stat'
sleep 8 | ssh -tt $K root@192.168.2.49
```

第一对会打出 `ioctl(TIOCSCTTY): I/O error`、`/dev/pts/0: No such file or directory` 与 `/dev/tty`
那行；第二对会打出 `/dev/pts/0`、非零的 `tty_nr`（`pts/0` 是 34816）以及 `root@ImmortalWrt:~#`。

第一段里的 `</dev/null` 就是这篇文档要说明的反面形态，只写一次好让人认得出来；它不是可以抄进探针的写法。
本仓库里所有交互判定都走 `dev_ssh_tty`，它从不把 stdin 从看守进程那里挪走。

## 历史版本的包 feed 与内核 ABI

官方镜像保留它发布过的每个版本的 release 目录，所以逐级升级或降级仍能指到一个更老的版本。内核不跟着走：
kmod feed 按内核段（kernel segment）归档，而内核段随每次内核升级改变。

| 版本 | kmods 段 | `kmod-usb-storage` | 用户态索引 |
|---|---|---|---|
| 25.12.0 | `6.12.87` | `6.12.87-r1` | 与 25.12.2 逐字节相同 |
| 25.12.1 | `6.12.94` | `6.12.94-r1` | 与 25.12.2 逐字节相同 |
| 25.12.2 | `6.12.103` | `6.12.103-r1` | 与 25.12.0 逐字节相同 |

2026-11-19 实测（`https://downloads.immortalwrt.org`）。三个版本的纯用户态索引是同一个文件，而
`targets/x86/64/kmods/<内核段>/` 只存在于它自己内核所对应的那个版本里。

- **现象。** 从更老版本抄来的 feed 行提供纯用户态包，却一个 kmod 都不提供。那个版本的索引里有 `htop`，
  没有 `kmod-usb-storage`，而正在运行的内核段对应的 kmod 目录在它下面回 404。
- **成因。** kmod 按内核构建归档，不按版本归档。对齐器会动一条 feed URL 的两半：
  - 它把每个 `/releases/<x>/` 与每个 `/kmods/<内核段>/` 改写成这个槽当前所跑版本的值
    （`platform/lib/upgrade/packages.sh:243-270`）。
  - 内核段取自目标基底自带的 feed 文件，而不是猜一个内核构建 hash
    （`platform/lib/upgrade/packages.sh:228-241`）。
- **影响面。** 只有 kmod feed 需要历史目录，因为三个版本的纯用户态索引逐字节相同。仍指向别的版本的 feed 会让
  跟随记录成 `packages=limited packages_reason=feeds-stale`（`packages.sh:1109-1118`）。
  `distfeeds.list` 与 `repositories.d/*.list` 正是对齐器要动的文件，写在那里的历史 release 会在下一跳被搬到
  正在运行的版本上。
- **规避。**
  - 把历史 feed 放进 `/etc/apk/repositories.d/customfeeds.list`。对齐器与跟随的 feed 探测都跳过这个文件
    （`packages.sh:442-446`、`packages.sh:701-708`、`platform/lib/ab-net-probe.sh:296-305`）。
  - 按内核段取 kmod，让每个包的版本跟着基底所跑的内核段走。
  - 某个内核段不再提供时，把它的索引、`.sig` 与 apk 镜像到本地 HTTPS feed 并保住签名，再让
    `customfeeds.list` 指向它（[update.zh-CN.md](update.zh-CN.md#自建-feed)）。
  - `ab-packages sources <name>` 给出某个包的来源与完整 URL
    （[update.zh-CN.md](update.zh-CN.md#包域的命令)）。

## 目标 release 不发布的包

跨版本迁移可能让 `world` 文件里留着目标 release 从未构建过的包名。这样一个名字会让之后每一次 apk 事务都
解不出来，所以跟随会在事务之前把它从 `world` 里摘掉。不卸载任何东西，也不碰任何配置。

- **现象。** 跟随会打出摘掉的条数与包名：
  `packages: dropped 1 world entr(y|ies) this base does not offer: <names>`
  （`platform/lib/upgrade/packages.sh:2258-2260`）。同一次启动里，`ab-slot status` 照旧打印 `packages=` 与
  `packages_reason=` 这一对（[install.zh-CN.md](install.zh-CN.md#怎么读-packages-与-packages_reason)）。
  如果剪完之后 world 里不剩这个 release 发布的任何包，记录写成 `packages=limited packages_reason=pruned`
  （`packages.sh:1151-1154`）。
- **成因。** `world` 的寿命比供给它条目的那个 release 长。apk 会为一个选不出来的名字拒绝整个集合，于是跟随事务、
  `ab-packages update` 与手敲的 `apk add kmod-x` 都栽在同一个条目上（`packages.sh:963-983`、
  `packages.sh:2248-2254`）。
- **影响面。** 剪枝只重写 `/etc/apk/world`，别的都不写（`packages.sh:877-921`）。它不卸载包：包的文件与
  `/etc/config` 原样留着（`packages.sh:972-975`），`/data` 不参与。版本已经消失的 pin 会被保留，因为索引仍然
  提供这个名字（`packages.sh:856-875`、`packages.sh:1034-1038`）。两道闸门拦着它：
  - 索引对任何名字都答不上来时，不能当作这个 release 什么都不提供的证据，因此一条都不剪
    （`packages.sh:924-961`、`packages.sh:1026-1031`，原因 `index-unusable`）。
  - 调用方知道索引刷新失败时会如实上报，同样一条都不剪（`packages.sh:1018-1025`，原因 `index-stale`）。
- **规避。**
  - 降级前读一次 `packages=` 与 `packages_reason=`，首次启动之后再读一次
    （[install.zh-CN.md](install.zh-CN.md#怎么读-packages-与-packages_reason)）。
  - 跳变前先跑 `ab-slot packages snapshot`，把每个包当前的已装版本记下来，之后可以重放
    （[update.zh-CN.md](update.zh-CN.md#包更新)）。
  - 目标 release 不发布的包会以现有版本继续运行。要推动它，需要一个提供它的 feed，或一份装机时留住的本体
    （[update.zh-CN.md](update.zh-CN.md#把本地包的本体留住)）。

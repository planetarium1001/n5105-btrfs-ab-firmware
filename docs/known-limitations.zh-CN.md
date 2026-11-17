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

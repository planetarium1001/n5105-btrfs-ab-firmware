# 从 feed 更新一台机器

[English](update.md) | **简体中文**

本页是「机器从 U 盘以外的地方自己更新」所需两件事的契约：**它能读的 feed**，以及
**一次更新最多能跨多远**。内容包括配置文件、两条命令、需要你确认的提示、全部退出码与
`reason=` token，以及发布方怎么自己造一个 feed。

只装一个已经在磁盘上的 payload、或者救援一台引导器写到一半被打断的机器，见
[install.zh-CN.md](install.zh-CN.md)。本页只补「取件」这一段。

## 开始之前

你需要一台已经从已提交槽位启动、并且通过了健康检查的机器：用 `ab-slot status` 确认，
它必须报 `p4=ok` 和一个 committed 槽位。你还需要一条能到 feed 的网络路径。

设备侧不新增任何更新状态。本页不会往 `ab/state.json` 里加文件，也不会改变槽位怎么被写：
`ab-upgrade --feed` 只负责下载 payload、校验它，然后把它交给 `ab-upgrade <payload>`
走的**同一份**校验与安装代码。

有两件机器必须做得到、但并不保证的事：

* 用 HTTPS 取一个文件。优先 `uclient-fetch`，其次 busybox `wget`；两者都没有时命令以
  `feed-no-fetcher` 拒绝，而不是走到一半才失败。如果机器两者都没有，可以用
  `UPDATE_FETCH_CMD` 每次调用临时指定一个取件命令（见[配置一个 feed](#配置一个-feed)）。
* 把 payload 写进一个装得下它的目录。默认是 `/tmp/ab-feed`，在这块板子上那是内存；
  `AB_FEED_DIR` 可以把它指到 p4 上的目录。

## 三个版本号

一次更新由三个数字描述。它们并列显示，因为回答的是不同的问题，而且任何一个都不能从
另一个推出来。

| 数字 | 来自哪里 | 含义 | 决定风险级别吗 |
| --- | --- | --- | --- |
| `base` | 发布的上游版本，例如 `25.12.2`；记录在槽位 `/etc/platform-release` 的 `UPSTREAM_VERSION` | 底下的 ImmortalWrt 发布：rootfs、内核、包基础都跟着它走 | 决定，而且只有它决定 |
| `kernel` | 这次构建的内核包版本，例如 `6.12.103` | payload 会装哪个内核。它通常跟着 `base` 走，有时不跟 | 不决定，只展示 |
| `platform` | 本项目自己的平台层，即 `PLATFORM_VERSION`，例如 `0.0.8` | 我们在同一个 `base` 上发布过多少次。它数的是我们的发布，不是系统的 | 不决定，只展示 |

`base` 不变、只有 `platform` 变的更新是普通的低风险更新：变的是平台层（脚本、默认值、
菜单），底下的系统没变。这就是为什么决定风险的是 `base`，也是为什么一个只写 `0.0.8`
的提示会把用户真正需要知道的东西藏起来。

风险级别总是取三个比较里最严重的一档：同时跨 minor 和若干 patch 的一次跳跃，算 minor，
不算 patch。

## 配置一个 feed

配置只有一个文件 `/etc/ab/update.conf`，与 `/etc/net-defaults.conf` 同样是
`key=value` 风格，`#` 起注释。文件缺失不是「用默认值」，而是拒绝。

```
UPDATE_FEED_URL=https://example.org/n5105/feed/v1
UPDATE_CHANNEL=stable
UPDATE_VERIFY=sha256
```

| 键 | 必填 | 作用 |
| --- | --- | --- |
| `UPDATE_FEED_URL` | 是 | feed 所在的目录。设备取 `<url>/index.txt`，条目自己没有 `url` 时取 `<url>/<payload>`。必须以 `https://` 开头，其它值以 `feed-conf-url` 拒绝 |
| `UPDATE_CHANNEL` | 否，默认 `stable` | 这台机器跟哪一条发布线。索引自己声明 `channel`，不一致以 `feed-index-channel` 拒绝，所以机器不会悄悄装上 `edge` 的发布 |
| `UPDATE_VERIFY` | 否，默认 `sha256` | 下载下来的文件怎么校验。本版本只实现 `sha256`，其它值是 `feed-verify-unsupported`，为将来的签名校验留位 |
| `UPDATE_PIN` | 否 | 这台机器自动更新到的最高的 `platform` 版本。由 `ab-upgrade --pin` 写入、`ab-upgrade --unpin` 删除，见[把机器钉在某个发布上](#把机器钉在某个发布上) |

`ab-upgrade --feed-url <url>` 可以在单次调用里覆盖 `UPDATE_FEED_URL`，试一个镜像不必改
文件。文件本身仍然必须存在。

`UPDATE_FETCH_CMD` 是给「取件器做不到 feed 需要的事」的机器留的口子：一旦设置，它的值会
以 `sh -c "<cmd>" ab-fetch <url> <输出文件>` 运行。测试用的就是它；在特殊传输后面放一台
机器也用它。

## 检查有没有更新

```sh
ab-upgrade --feed-check
```

这条命令读配置、取索引、把查到的东西打出来。它不写任何东西、不下载 payload、不碰槽位。
有更新时它打一行字段顺序固定的机器可读输出：

```
platform=0.0.6 platform_available=0.0.8 base=25.12.2 base_available=25.12.2 kernel=6.12.103 kernel_available=6.12.103 span=patch 2 level=Z1 status=update
```

`platform` 与 `base` 是运行槽位里的值，`kernel` 是正在跑的内核（`uname -r`）；带
`_available` 的字段是索引里最新条目给的值。`span` 是 `base` 的差值，写成 `patch N`、
`minor N`、`major N` 或 `none`；`level` 是[风险级别](#风险级别与各自的确认强度)那一节里的级别。

`status` 说这台机器可以做什么，是要分支判断的那个字段：

| 输出 | 退出码 | 含义 |
| --- | --- | --- |
| `status=update`，`level=Z1` … `X1` | `10` | 有更新的发布。级别说明这次跳跃有多少被测试覆盖 |
| `0.0.8 is the newest release (base 25.12.2)`，下一行是 `status=current` | `0` | 无事可做。feed 里最新的发布就是正在跑的这个 |
| 字段行带 `pin=<版本> status=pinned` | `0` | 有更新的发布，但 `UPDATE_PIN` 把这台机器按住了 |
| 字段行带 `level=downgrade status=downgrade` | `0` | feed 里所有条目都比当前运行的旧。查到降级仍然是一次成功的查询；拒绝它的是 `--feed` 那条命令 |

任何拒绝（没有配置、feed 不可达、索引解析不了）都以 `74` 退出并给一个 `reason=` token，
不给字段行，因为此时没有一句真话可说。

## 安装更新

```sh
ab-upgrade --feed
```

命令重复一次上面的查询、打同一行字段，然后显示更新块并请求确认。确认后它把 payload 下到
`${AB_FEED_DIR:-/tmp/ab-feed}`，按索引核对文件大小与 sha256，然后进入普通安装路径：与
`ab-upgrade <payload>` 完全相同的 manifest、成员、内核模块、空间、引导器与冲突检查。之后
机器就与一次本地升级完全一样：非活动槽位被准备好，下次启动试用它，健康检查不过就回到原来
的槽位。

| 选项 | 什么时候用 |
| --- | --- |
| `--yes` | 命令没有终端可以提问时（脚本、任务、没有 TTY 的 SSH 单行命令）。没有它，非交互运行会以 `feed-noninteractive` 拒绝，而不是等一个永远不会来的输入 |
| `--direct` | 跨大版本的跳跃，你想一步装到最新 |
| `--stepwise` | 跨大版本的跳跃，你想一条命令装一个。它装的是比当前大的最小那个发布；不排队，所以每一跳都有自己的重启、健康检查与提交 |
| `--force` | feed 里最新的发布比当前运行的旧，而你仍然要装。没有它，降级以 `feed-would-downgrade` 拒绝 |
| `--feed-url <url>` | 本次调用换一个镜像 |

`--direct` 与 `--stepwise` 是 `--feed` 的选项；单独给出属于用法错误，退出 `2`。两个选项
都可以出现在命令行任意位置。

这条命令写出的行与本地安装写出的行是同一套：按
[install.zh-CN.md](install.zh-CN.md) 里的做法，把命令用 `tee` 灌进
`/boot/ab/log/upgrade.log`。拒绝行还会额外镜像到串口控制台，所以一台只有串口的机器也会说
清楚它为什么停下。

安装成功之后机器还没有变化：用 `ab-slot status` 看到另一个槽位是 `pending`、
`next=<slot>`，然后重启。用 `apk` 装的包**不会**被这条路更新。让它们对齐到新的 base 是
另一套操作、另一组命令，因为一个解析不了的包不该把一次已经通过检查的系统更新回滚掉。

## 更新提示说了什么

提示是三行身份加三行判定。除 `Proceed?` 那个问题本身走 stderr（这样 stdout 被重定向到
文件时它仍然可见）之外，全部写到 stdout，日志能完整留下。

```
Update  base     25.12.2 -> 25.12.5
        kernel   6.12.103 -> 6.12.110
        platform 0.0.6 -> 0.0.8
  Change  PATCH ×3   · the entries above are what this update brings
  Tested  YES        · patch range covered in CI
  Risk    LOW        · running system replaced; previous slot is the way back
Proceed? [y/N]
```

三行身份是唯一说明**变了什么**的地方：每行写成 `当前 -> 候选`，没有变化的一项两侧是同一个
数字。三项都不是从级别推出来的。

三行判定回答三个不同的问题，顺序固定：

* `Change` 只说这次跳跃的**大小**：`NONE`、`PATCH ×N`、`MINOR +N` 或 `MAJOR +N`。它从
  不声称哪些成员跟着变了；那由上面的身份行说。
* `Tested` 只陈述 **CI 覆盖到哪**，是事实，不带含糊：`YES`、`PARTLY` 或 `NO`。
* `Risk` 说明这里没被覆盖的部分意味着什么：`LOW`、`REAL`、`HIGHER` 或 `UNKNOWN`。

判定词是封闭词表，一律大写，与解释之间用 `·` 分隔。圆括号里是附带说明，方括号里是推荐
标记，例如 `[recommended]`。建议备份的级别在 `Risk` 之后多一行 `Backup`；不选路线就不
能继续时才有 `Route` 行。

## 风险级别与各自的确认强度

级别说的是**测试覆盖**，不是改动大小，而且只由 `base` 算出。它改变的是你被要求做什么，
从不改变机器做什么：每个级别最后都走同一套校验、同一次写入。

| 级别 | 条件 | `Tested` | `Risk` | 你必须做什么 |
| --- | --- | --- | --- | --- |
| Z1 | 同一个 `base`，patch 差 ≤ 3，包括完全不差 | 已覆盖 | 低 | 用 `y` 确认，或加 `--yes` |
| Z2 | 同一个 `base`，patch 差 > 3 | 未覆盖（超出范围） | 低但未覆盖 | 用 `y` 确认，或加 `--yes`；建议备份 |
| Y1 | major 相同，minor 差正好 1 | 部分覆盖 | 真实（real） | 用 `y` 确认，或加 `--yes` |
| Y2 | major 相同，minor 差 > 1 | 未覆盖 | 更高（higher） | 用 `y` 确认，或加 `--yes`；建议备份 |
| X1 | 跨 major | 未覆盖 | 未知（unknown） | **必须**选 `--direct` 或 `--stepwise`；建议备份 |

Z1，只换平台层：`base` 与 `kernel` 都不动，只有我们这一层变了。

```
Update  base     25.12.2 -> 25.12.2
        kernel   6.12.103 -> 6.12.103
        platform 0.0.7 -> 0.0.8
  Change  NONE       · platform layer only; base and kernel left as they are
  Tested  YES        · same-base update covered in CI
  Risk    LOW        · no kernel or package base change
Proceed? [y/N]
```

Z1，一个短的 patch 跳跃：

```
Update  base     25.12.2 -> 25.12.5
        kernel   6.12.103 -> 6.12.110
        platform 0.0.6 -> 0.0.8
  Change  PATCH ×3   · the entries above are what this update brings
  Tested  YES        · patch range covered in CI
  Risk    LOW        · running system replaced; previous slot is the way back
Proceed? [y/N]
```

Z2，超出覆盖范围的 patch 跳跃：

```
Update  base     25.12.2 -> 25.12.9
        kernel   6.12.103 -> 6.12.110
        platform 0.0.6 -> 0.0.8
  Change  PATCH ×7   · the entries above are what this update brings
  Tested  NO         · span outside the covered range
  Risk    LOW        · patches rarely change behaviour, but uncovered
Backup    ab-backup --help   (recommended)
Proceed? [y/N]
```

Y1，前进一条发布线：

```
Update  base     25.12.2 -> 25.18.0
        kernel   6.12.103 -> 6.12.140
        platform 0.0.8 -> 0.1.2
  Change  MINOR +1   · a new release line; the entries above are what this update brings
  Tested  PARTLY     · neighbouring lines built together; one cross-line upgrade in CI
  Risk    REAL       · installed packages may need rebuilding for the new base
Proceed? [y/N]
```

Y2，前进几条发布线：

```
Update  base     25.12.2 -> 25.19.0
        kernel   6.12.103 -> 6.12.150
        platform 0.0.8 -> 0.3.0
  Change  MINOR +2   · the entries above are what this update brings
  Tested  NO         · lines this far apart are not built together
  Risk    HIGHER     · compatibility is less certain than a neighbouring line
Backup    ab-backup --help   (recommended)
Proceed? [y/N]
```

X1，跨一条新的大版本线。这里没有 `y`：没有选路线之前命令直接拒绝，并把两条路线与理由
一起打出来。

```
Update  base     25.12.2 -> 26.0.0
        kernel   6.12.103 -> 6.18.2
        platform 0.0.8 -> 1.0.0
  Change  MAJOR +1   · a new major line; the entries above are what this update brings
  Tested  NO         · nothing here crosses a major line
  Risk    UNKNOWN    · the package base may not be compatible
Backup    ab-backup --help   (recommended)
Route     --stepwise   install the next release, one at a time   [recommended]
          --direct     install the newest release in one step
ab-upgrade: refused, reason=feed-route-required
```

`--stepwise` 是沿着索引走的：它装比当前大的最小那个发布，所以落后几条线的机器是一段一段
重复同样熟悉的跳跃。如果索引里已经不再保留中间某个发布，命令以 `feed-no-such-release`
拒绝，而不是跳过缺口直达。

## 把机器钉在某个发布上

`UPDATE_PIN` 是自动路径的上界，不是锁：

```sh
ab-upgrade --pin 0.0.8      # ab-upgrade: pinned to 0.0.8
ab-upgrade --unpin          # ab-upgrade: pin removed
```

两条命令都只改 `/etc/ab/update.conf` 的一行、不联网、不动文件里的其它内容。不是
`MAJOR.MINOR.PATCH` 的版本以 `pin-invalid-version` 拒绝。

pin 的效果：

* `--feed-check` 照常工作，输出 `status=pinned` 并带上候选与 pin，退出 `0`：被按住的机器
  不会被追着升级。
* `--feed` 在候选越过 pin 时以 `feed-pinned` 拒绝。候选等于 pin 时正常安装。
* `--stepwise` 以 pin 为上界，走到就停。
* pin 低于已装版本不算错误：查询会加一行
  `warning pin-below-installed (UPDATE_PIN=0.0.5, running 0.0.7)`，因为常见原因是操作者升级
  完忘了把 pin 往前挪。
* `ab-upgrade <payload>` 完全不受 pin 影响。pin 是阻止机器自己往前跑的东西，拦不住一个
  点名了文件的人。

删掉那一行，或者 `--unpin`，机器就解除约束。pin 不写进 `ab/state.json`，也不影响 `apk`。

## 包更新

系统更新换的是一个槽；包是另一个事务，也有自己的回退方式。两者都落在可写层，而且都不是自动的：
你要求它才发生。

```sh
ab-slot packages list            # 本层已有的快照，新的在前
ab-slot packages snapshot        # 现在记下 world 与每个已装包的版本
ab-slot packages upgrade         # 先快照，再 apk update && apk upgrade
ab-slot packages revert          # 按最新一份快照回放版本
```

`upgrade` 只有在 `ab-slot status` 报 `packages=aligned` 时才肯跑：这个字段表示可写层的 `world`
钉着本槽正在跑的内核、`distfeeds` 指向本槽所在的发布。在旧钉子上直接升包，会为机器并没在跑的内核
装模块。

快照是 `<layer>/apk/snapshots/` 下的文本：base 与 platform 版本、每个 world 条目、每个已装包及其版本。
只保留最近三份。`revert` 用 `apk add <name>=<version>` 回放，且只允许在同一个 base 上：跨 base 时
那些版本是按另一个内核和 libc 构建的，那件事归 `ab-slot rollback` 管。源里已经下架的包会被逐条报出来，
其余照常回放：`revert result=partial` 会点名每一个，退出码仍是 0。

两条回退路径并列：

| 想撤销什么 | 用什么 | 恢复什么 |
| --- | --- | --- |
| 上一次系统更新 | `ab-slot rollback` | 另一个槽：它的 base、它的平台层与它的包 |
| 同一 base 上的包改动 | `ab-slot packages revert` | 快照里的版本，仅此而已 |

两者都写 `upgrade.log`；都不会自己跑。

## 退出码

| 退出码 | 含义 |
| --- | --- |
| `0` | 无事可做，或者什么都没做：`--feed-check` 发现跑的就是最新或候选被 pin 按住，查询只查到降级，或者 `--pin` / `--unpin` 成功。在提示里回答 `n` 也是 `0`，什么都没写 |
| `1` | 检查都过了之后某一步失败，例如下载目录满了、库文件缺失。payload 或机器已经越过校验，然后断了 |
| `2` | 用法错误：未知选项、`--direct` / `--stepwise` 没有配 `--feed`、或者多给了一个 payload 参数 |
| `10` | `--feed-check` 查到更新的发布。这不是错误也不是成功：它就是那个问题的答案，脚本可以据此分支 |
| `74` | 在写任何东西之前拒绝。输出行是 `ab-upgrade: refused, reason=<token>`，token 见下表 |

本地安装路径的退出码（`0`、`1`、`74`，以及拒绝之后磁盘上留下什么）见
[install.zh-CN.md](install.zh-CN.md)。

## reason 表

每次拒绝都点名一个 token，token 跨版本稳定，脚本或手册可以按它匹配。输出行永远是
`ab-upgrade: refused, reason=<token>`，而 `1` 输出的是 `ab-upgrade: failed, reason=<token>`。

| reason | 退出码 | 含义与怎么办 |
| --- | --- | --- |
| `no-feed-config` | 74 | `/etc/ab/update.conf` 不存在。建一个并写好 `UPDATE_FEED_URL`；命令不会猜地址 |
| `feed-conf-missing-url` | 74 | 文件存在但没有 `UPDATE_FEED_URL` |
| `feed-conf-url` | 74 | `UPDATE_FEED_URL` 不是 `https://` 地址。不加密的 feed 被拒绝：索引里的摘要只有在索引本身无法被中途替换时才能保护 payload |
| `feed-conf-channel` | 74 | `UPDATE_CHANNEL` 既不是 `stable` 也不是 `edge` |
| `feed-verify-unsupported` | 74 | `UPDATE_VERIFY` 指定了本版本没有实现的模式。只有 `sha256` |
| `feed-unreachable` | 74 | 索引或 payload 取不到：没有路由、解析不到域名、`404`，或者取件命令非零退出 |
| `feed-no-fetcher` | 74 | 机器既没有 `uclient-fetch` 也没有 `wget`，而 `UPDATE_FETCH_CMD` 没设 |
| `feed-index-version` | 74 | 索引第一行不是 `AB-FEED 1`，或者 `platform` / `base` / `kernel` 不是 `MAJOR.MINOR.PATCH` |
| `feed-index-field` | 74 | 必填字段缺失、字段出现在 `entry` 块之外、出现未知键，或 `size` / `sha256` 格式不对 |
| `feed-index-order` | 74 | 条目不是严格的从新到旧。发布方破坏了排序规则；设备拒绝整个索引而不是替它排序，因为排过序的视图会掩盖一个停止维护顺序的 feed |
| `feed-index-channel` | 74 | 索引声明的 `channel` 与这台机器跟的那条不一致 |
| `feed-payload-missing` | 74 | 下载结束了但文件不在 |
| `feed-size-mismatch` | 74 | 下载下来的文件大小与索引不符，所以什么都不装；半包在拒绝之前就被删掉 |
| `feed-digest-mismatch` | 74 | 下载文件的 sha256 与索引不符。这算下载失败或文件被改，从不当警告，也不会安装任何东西 |
| `feed-download-space` | 74 | 下载目录的剩余空间不到 payload 的 110%。把 `AB_FEED_DIR` 指到 p4 而不是 `/tmp` |
| `feed-pinned` | 74 | `UPDATE_PIN` 把这台机器按住，低于候选。`ab-upgrade --unpin`，或者 `ab-upgrade --pin <更新的版本>` |
| `feed-would-downgrade` | 74 | feed 里最新的发布比当前运行的旧。确实要装就加 `--force` |
| `feed-route-required` | 74 | 这次跳跃跨了大版本。选 `--stepwise`（一次一个发布）或 `--direct`（直接到最新） |
| `feed-no-such-release` | 74 | `--stepwise` 在已装版本与最新之间找不到发布：feed 的索引被裁过。向发布方要回缺的发布，或者用 `--direct` |
| `feed-noninteractive` | 74 | 没有终端可以提问。加 `--yes` 接受提示，或者从终端里跑这条命令 |
| `platform-release-missing` | 74 | 运行槽位的 `/etc/platform-release` 里没有 `PLATFORM_VERSION` 或没有 `UPSTREAM_VERSION`，机器说不清自己在跑什么。重装平台层 |
| `feed-library-missing` | 1 | `ab-version.sh` 或 `ab-feed.sh` 不在机器上：平台层不完整 |
| `pin-invalid-version` | 74 | `--pin` 给的不是 `MAJOR.MINOR.PATCH` |
| `pin-write-failed` | 74 | `/etc/ab/update.conf` 重写失败。检查 `/etc` 可写且有余量 |
| `cannot-create-workdir` | 1 | `/tmp` 下的临时目录建不出来 |
| `cannot-create-feed-dir` | 1 | 下载目录建不出来。检查 `AB_FEED_DIR` |

payload 下载下来之后可能被拒绝的那些 reason 属于安装器，列在
[install.zh-CN.md](install.zh-CN.md)：从那一刻起，feed 路径就是本地路径。

## 跨度大之前先备份

Z2、Y2、X1 会打一行 `Backup    ab-backup --help   (recommended)`。那只是建议和一条你自己
去执行的命令，没有任何东西替你调 `ab-backup`。之所以打印而不自动执行，是因为它需要目标
介质和装得下这个包的空间，而一次悄悄失败的备份比没有备份更糟。

这里备份买到的是什么：这条更新路径永远能退回**上一个槽位**，因为今天在跑的槽位没有被碰过。
但一旦旧发布从 feed 里消失，它不能把你退回**上一个发布**，也不能找回你在 `/data` 下改过的
文件。三种产物、各自能恢复到多大的盘、以及恢复决策树，见
[backup.zh-CN.md](backup.zh-CN.md)。

升级出问题之后的恢复路径见 [lifecycle.zh-CN.md](lifecycle.zh-CN.md)（更新事务与自动回退）
以及 [install.zh-CN.md](install.zh-CN.md)（引导器写到一半被打断）。

## 自建 feed

feed 就是一个用 HTTPS 提供的目录，里面放两类东西：`index.txt` 和它点名的 payload。任何
静态托管都行，GitHub Releases 也行。我们的 CI 只是第一个发布方，不是必须条件。

`index.txt` 故意做成行式的：发布方用 `sha256sum` 加一句 `printf` 就能生成，设备只用 `awk`
就能读。

```
AB-FEED 1
channel   stable
generated 2026-11-13T00:00:00Z
entry
  platform 0.0.8
  base     25.12.2
  kernel   6.12.103
  payload  n5105-ab-25.12.2-upgrade.tar
  size     20480000
  sha256   3f2a7c1d4e5b8091a2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f607182
  url      https://example.org/n5105/feed/v1/n5105-ab-25.12.2-upgrade.tar
end
```

发布方必须守的规则：

| 规则 | 为什么 |
| --- | --- |
| 第一行是 `AB-FEED 1` | 这是格式版本。不认识的版本被拒绝，而不是猜着读 |
| `channel` 在头部声明一次 | 一台机器只跟一条线；不一致被拒绝 |
| 每个发布被 `entry` … `end` 包起来 | 块外的字段被拒绝，所以一个被截断的文件不会被读成一个更短的 feed |
| `platform`、`base`、`kernel`、`payload`、`size`、`sha256` 全都要有 | 六个事实，其中三个是身份。任何一个都不从另一个推 |
| `platform`、`base`、`kernel` 必须是 `MAJOR.MINOR.PATCH` | 比较是逐段按整数做的；`-r1` 这类后缀属于包，不属于这三个字段 |
| `size` 是 payload 的字节数，`sha256` 是它的摘要 | 设备在两样都核对通过之前什么都不装，不符按下载失败处理 |
| 条目按 `platform` 从新到旧严格排序 | 设备会检查顺序，不满足就拒绝整个索引 |
| `url` 可选，写了就要是绝对地址 | 不写时设备用自己的 `UPDATE_FEED_URL` 配 `payload` 解析，这样同一个 feed 才能被镜像 |
| `notes` 可选 | 条目可以带一个给人看的链接，例如发布页。设备会解析它，此外不做任何事 |

`kernel` 字段是内核**版本**（`6.12.103`），不是内核包（`6.12.103~<源码 hash>-r1`）：包后缀
每次重建都会变，对「跑的是哪个内核」什么也没说。

用流水线已经写出的发布目录生成一份索引：

```sh
scripts/ci/feed-index.sh --out /srv/feed/v1/index.txt \
  --channel stable \
  --base-url https://example.org/n5105/feed/v1 \
  --release /srv/releases/v0.0.8 \
  --release /srv/releases/v0.0.7
```

每个 `--release` 目录是一个已发布的版本，里面必须有 `release-notes.md`（记录平台、上游与
内核版本）、`SHA256SUMS`，以及它点名的 payload tar。排序由脚本自己做，所以目录以什么顺序
给出都行。它会重新算每个 payload 的摘要，并且拒绝 `SHA256SUMS` 与旁边文件不一致的目录——
一份和 payload 对不上的已发布索引，比没有索引更糟。

`scripts/ci/release.sh` 会替你跑这一步：对它知道内核版本的每个发布，把 `index.txt` 加进
发布资产，所以一次发布本身就是一条 feed 条目，不需要谁手工维护清单。把更早的发布目录通过
`CI_FEED_HISTORY` 传进去，它们会进同一份索引，`--stepwise` 才有地方逐级走。

还有两件 feed 目前做不到的事：它没有签名（`UPDATE_VERIFY` 给签名模式留了位，但还没有实现），
以及它带的摘要只和送它来的那条 HTTPS 连接一样可信。这与从发布页用浏览器下载是同一级的信任，
也正是 feed 地址必须是 `https://` 的原因。

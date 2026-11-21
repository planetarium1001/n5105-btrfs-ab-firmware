# 插件：声明式的包来源

[English](plugins.md) | **简体中文**

本页是「写一个文件就给机器加一个包来源」的契约，以及那个来源加进来之后允许做什么。内容包括
声明文件的字段、`ab-packages plugins` 的四个子命令、三条护栏、源不回答时意味着什么，以及怎么
把整件事关掉。

包更新是一个有自己的回退方式的事务（见 [update.zh-CN.md](update.zh-CN.md)）。插件是机器拿到
「发布 feed 没带的来源」的方式——既不编辑 `/etc/apk/repositories.d`，也不让插件自己的任何东西
被执行。

## 插件是什么

插件就是一个目录加里面一份声明；一次 check 会在旁边再留下一个文件。除此之外什么都不读：

```
/etc/ab/plugins.d/<label>/plugin.conf     声明，由人写
/etc/ab/plugins.d/<label>/.verdict       由 `plugins check` 写，不由人手写
```

`<label>` 就是目录名，也是每条命令称呼这个插件用的名字。它必须匹配 `[a-z0-9][a-z0-9_-]*`：
label 会出现在消息里、出现在 apk 命令行的 `plugin:<label>` 里、出现在 `/tmp` 下的路径里，所以
只允许在任何地方都不需要加引号的字符。

这个目录在 `/etc/ab` 下，也就是可写层。系统更新替换的是系统树，不会搬动 `/etc/ab`，所以声明
能活过一次升级，升级也不会从 payload 里带进来一份。

**插件是数据，不是程序。** 它不能给安装加一步、给启动加一个钩子、给升级路径加一条命令；整套
词汇只有「若干个 apk feed」和「若干个包名」。这是一条刻意的边界，而不是没做完的功能：插件能
做错的事被它能说出口的话限住，插件声明的任何东西都不会在升级之前、之中、之后被执行。

插件进入 apk 的方式只有一条。每次 apk 调用前，在 `/tmp` 下拼出一个 repositories 文件：机器
自己的 feed 文件按 apk 的顺序（`repositories.d/*.list`，然后 `distfeeds.list`，然后
`repositories`），后面接上这次事务可以读的每个插件的 feed。apk 从上往下读一个 repositories
文件，平局时基底必须赢，所以插件的行排在最后。

那些机器自己的文件是只读的，不会被写。这里什么都不编辑 `/etc/apk/repositories.d` 或
`distfeeds.list`，所以对齐器与跟随看到的仍然是它们为之而建的那个基底；插件源也不会因为自己
消失就把某个 world 条目变成 `gone`。而在没有声明任何插件时，apk 命令行与插件出现之前逐字节
相同——`--repositories-file` 只在有插件贡献 feed 时出现。

交给 apk 的那个文件放在 `mktemp` 建出来的目录里（权限 `700`），并且随着用它那条命令一起删掉。
`/tmp` 下一个固定名字，就是别人可以预先放一个符号链接的名字，而本工具是以 root 打开这个文件的。

## 声明文件

```
api = 1
kind = packages
enabled = yes
feed = https://example.org/packages/packages.adb
package = luci-app-example
```

| 键 | 必须 | 取值 | 含义 |
| --- | --- | --- | --- |
| `api` | 是 | `1` | 这个文件实现的契约。为更高 api 写的声明会被拒绝，而不是读到一半 |
| `kind` | 是 | `source`、`packages` | 它贡献什么。`source` 贡献 feed；`packages` 点名要装的包，也可以同时带 feed |
| `enabled` | 否，默认 `yes` | `yes`、`no` | 开关。`no` 让插件不进入任何事务，而不必删掉任何东西 |
| `feed` | `kind = source` 时；可重复 | 一个 `http(s)://` URL，不含空白 | 一个 apk 仓库，写法与机器自己的 feed 文件一致：索引地址 `.../packages.adb`。在服务器按 apk 要的名字发布索引时，写裸目录也行；本项目在真机上跑过的是索引地址这一种 |
| `package` | `kind = packages` 时；可重复 | `[A-Za-z0-9][A-Za-z0-9._+-]*`（一个 apk 包名） | `plugins apply` 要装的一个名字 |
| `key` | 否 | `/etc/apk/keys/<name>.pem` | 这个 feed 本该用哪把钥匙校验。本版本只检查文件在不在，从不导入钥匙 |
| `arch` | 否，默认 `noarch` | `noarch` | 唯一取值。按架构发布的 feed 会被拒绝，见[护栏](#护栏) |
| `allow-shadow` | 否，默认 `no` | `yes`、`no` | 是否允许一个 feed 提供 world 里某个包的更高版本 |
| `allow-kmod` | 否，默认 `no` | `yes`、`no` | 是否允许一个 feed 或一个包是内核模块树 |

关于这个文件本身有两条规则，它们出自同一个理由：一份「说了机器并不实现的东西」的声明，绝不能
读成一份能用的声明。

* 未知的键是拒绝（`plugin-unknown-key`），不是被跳过的一行。把 `package =` 打成 `pakage =`
  会什么都不装、也什么都不说，这正是这条规则要防止的失败；
* 只能出现一次的键只能出现一次（`plugin-key-duplicate`）。只有 `feed` 与 `package` 可重复。

`#` 开始一行注释，空行被忽略，`=` 两边的空格是习惯而非语法——解析器两边都会去掉。

静态规则管的也不只是键名，还有取值：label 不是 `[a-z0-9][a-z0-9_-]*`、`api` 不是 `1`、
`kind` 不在两个取值里、`enabled` 既不是 `yes` 也不是 `no`、`kind = source` 却没有 `feed`、
`kind = packages` 却没有 `package`、URL 不是 `http(s)` 或带空白、`package` 不是 apk 包名、
key 路径不在 `/etc/apk/keys/` 下、key 文件不存在。每一种都有[reason 表](#reason-表)里自己的
token，而一份错在两处的声明永远回答同一个「第一个」失败项，所以脚本可以拿这个答案做分支。

其中两条取值规则值得单独说，因为它们都是为了不让一份声明比它写出来的意思更大：

* `package` 的值是**`apk add` 命令行上的一个词**。`package = -X` 是一个仓库选项，
  `package = --allow-untrusted` 是 apk 仅剩的那道信任检查，而带空白的名字是两个名字。它们都
  不是包，每一种都是 `plugin-package-invalid`；
* `feed` 的值会成为 repositories 文件的一行，而 apk 会按空白切这一行。所以一个带空白的 URL
  实际上是两个来源，第二个从来没被上面那些规则看过——因此空白一律以 `plugin-feed-scheme` 拒绝。

## 四个命令

```sh
ab-packages plugins list                 # 声明了什么，以及上次 check 说了什么
ab-packages plugins check [<label>...]   # 网络阶段：feed 在不在、会不会 shadow
ab-packages plugins apply <label>        # 计划块、提问、一次 apk 事务
ab-packages plugins repos                # 一次事务会读的那个 repositories 文件
```

| 命令 | 回答什么 | 写什么 | 联网 |
| --- | --- | --- | --- |
| `list` | 一行一个声明，字段顺序固定：`label kind enabled checked reason feeds packages`；什么都没声明时是 `plugins=none` | 什么都不写 | 不 |
| `check` | 先跑静态规则，再对每个 feed 做一次 HEAD，然后问 apk 自己：这个来源提供 world 里某个包的更高版本吗 | verdict 文件 | 联网，而且是唯一联网的命令 |
| `apply` | 一次事务装上声明点名的包，前面照样是这块计划块与那个提问 | apk 自己的状态；不写 `/boot/ab/packages` | 不，除了 apk 自己要做的事 |
| `repos` | 把一次事务会读的文件按将要写出的样子打印：机器自己的 feed 在前，被放行的插件 feed 在后 | 什么都不写（`/tmp` 下一个文件，命令返回时删掉） | 不 |

`list` 是一张表，因为人们问它的问题就是关于列的：开没开（`enabled=`）、check 过没有
（`checked=`）、被拒的话为什么（`reason=`）。一行长这样：

```
label=istore kind=packages enabled=no checked=stale reason=none feeds=1 packages=1
```

`repos` 是调试与取证用的命令：它把文件打出来，于是「来源进去了」和「来源出来了」是你眼睛能
看到的事实，而不是从「某个包怎么没出现」推出来的结论。它还在 stderr 上说一句解释，说明上面
那些行里有几行来自插件。

`ab-packages sources <name>` 是归因出现的地方：属于某个已启用插件 feed 的来源打印成
`source=plugin:<label>`，而不是 `source=feed`，于是一个来自别人自家树的包不会被读成本项目发布的
包。回答的是 apk，而 apk 只认 `/etc/apk` 下的文件——插件的 feed 按设计不在那里。所以只要有插件
在贡献，同一个问题会再问一次，问的是「一次事务会读的那个文件」（机器自己的 feed 在前，插件的在
后），两个答案合并。什么都没声明时，这条命令问的和它历来问的完全一样。

`apply` 遵守本项目所有写操作的同一条规矩：先打印计划块，问这里每一次写操作都在问的那个问题
`Proceed and follow <n> packages? [y/N] `（`<n>` 是声明点名的包数），只有 `y`（或脚本用的
`--yes`）才开始事务。拒绝（回答 `n`）什么都不写，退出码 `0`。一份没有点名任何包的
声明回答 `plugin-nothing-to-install` 并以 `0` 退出，因为只有源的插件是一个能用的插件，只是
本来就没有东西可装。

`apply` 只受静态规则约束，别的不受。shadow 与可达性是 `check` 的问题：它们是关于**跟随**的
问题，而跟随会搬动没人点名的包；`apply` 只搬写下来的那些。所以在 `apply` 里点名一个插件，就是
决定执行它——包会从这个声明所点名的 feed 装上，无论它有没有 verdict——先跑
`plugins check <label>` 只是让这个决定变成有依据的决定，而不是唯一可读的那个。计划块在提问之前
就把插件和每一个包都列出来了，所以事务永远不会比屏幕上那几行更宽。

| 退出码 | 含义 |
| --- | --- |
| `0` | 完成，或无事可做 |
| `1` | 事务失败；它上面那行用 `apk-<rc>` 带上 apk 的状态 |
| `2` | 用法错误 |
| `74` | 在写任何东西之前拒绝 |

这里什么都不写 `/boot/ab/packages`。那一行记录描述的是「整个世界跟上了」（见
[update.zh-CN.md](update.zh-CN.md)）；一个插件的包清单不是那句话。

world 是另一个文件，而 `apply` 确实碰到它——通过 apk，不是自己动手。`apk add` 会把装上的每个
名字记进 `/etc/apk/world`，apk 正是靠它记住这个名字是被点名要的，而 `plugins apply` 跑的就是
一次普通的 `apk add`。所以插件装上的包从那一刻起就有 world 条目，而关掉插件之后它会怎样，见
[关掉一个插件](#关掉一个插件)。

## check 是这台机器唯一联网的地方

没有任何事务会去问 feed 在不在、会不会 shadow 什么。它读的是一次 check 写下的 verdict。这正
是升级与跟随路径保持离线、不会卡在超时上的原因，也是为什么 `check` 是唯一带挂钟上限的命令
（`AB_PLUGINS_CHECK_TIMEOUT`，默认 180 秒）。

一次 check 按这个顺序做四件事：

1. 上一节那些静态规则。一份用不起来的声明永远不会产生一次请求。
2. 对每个声明的 feed 做一次 HEAD，用的取件工具与超时和跟随自己的探测完全一致。不回答的 feed
   是 `feed-unreachable`，check 就停在这里：已经没有别的东西可比了。
3. 往 `/tmp` 下的缓存做一次 `apk update`，再对 world 里的裸包名跑一次 `apk policy`，两次都
   对着这个插件将要贡献的那个 repositories 文件。哪个来源赢是 apk 自己的事，所以两个版本谁
   大是问 apk 的，而不是在这里再实现一遍。
4. 写 verdict 到 `.verdict`：

```
verdict=ok
reason=none
checked=2026-11-21T03:12:44Z
conf=3f2a7c1d4e5b8091a2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f607182
```

verdict 才是答案，屏幕上那行不是：它是之后每个事务读的文件。所以写不下去的 check 会说
`plugin=<label> verdict=ok reason=verdict-unwritable` 并以非零退出——一个屏幕上写着 `ok`、背后
却没有文件的答案，是一句没人兑现的承诺，下一次事务读到的只会是上一次留下的东西。写不下去的
**blocked** verdict 会保留它查到的 token，并在同一行加上 `verdict-write=failed`：拒绝仍然是答案，
缺的只是这条答案的记录。

一个插件的 feed 要同时满足三件事才进入事务：`enabled = yes`、verdict 是 `ok`、verdict 里记的
摘要等于当前声明的摘要。任何一条不成立，feed 就会在 apk 调用那一刻被挡在外面，而且不吭声——
对于一个不许靠联网来决定的步骤，「fail closed」只能这么实现。

摘要正是**改过的声明必须重新 check** 的原因。改一行，旧 verdict 就不再代表这个文件：
`plugins list` 报 `checked=stale`，feed 在下一次 apk 调用时就已经不在 repositories 文件里，
既没有浪费时间也没有发出请求。跑一次 `plugins check` 写下新的 verdict，插件就又被放行。

`list` 一行里的 `checked=` 是四个词之一：

| 取值 | 含义 |
| --- | --- |
| `never` | 没人 check 过这份声明。它什么都不贡献 |
| `ok` | 上次 check 放行的正是现在这段文字 |
| `blocked` | 上次 check 拒绝的正是现在这段文字；`reason=` 带上 token |
| `stale` | check 过，但声明之后改了。在重新 check 之前什么都不贡献 |

stale 不是要机器去修的故障状态：它是这份声明在请求再看一眼。而被关掉的插件也可能仍然读作
`stale` 或 `never`，因为 check 不会为一个没有事务会读的插件花一次请求、也不会为它写 verdict。

## 护栏

三条规则界定了「一个声明的来源最多能是什么」。插件不能给自己发这三条里的任何一条；其中两条
是写在声明里的许可，剩下那一条没有别的取值。

`allow-shadow = no` 是默认值，它回答插件源带来的那个问题：它是否提供 world 里已经有的某个包
的**更高**版本？如果是，check 用 `shadow:<name>` 挡住它，并说出是哪个名字、哪两个版本。理由：
跟随是用一次 `apk upgrade` 搬动整个世界；一个悄悄提供 `htop 3.4` 而基底是 `3.3` 的 feed，
就是「没人提过的包在下次启动时动了」的来路，而发现这件事的机器是刚跨过一次发布的那台。
`allow-shadow = yes` 放行它，并在 verdict 里记 `shadow-allowed` 而不是 `none`，于是「这是
被有意接受的」留在记录上。通常比允许 shadow 更好的做法是：在 world 里把基底版本钉住。

`allow-kmod = no` 是默认值。包名以 `kmod-` 开头的包、以及 URL 里含 `/kmods/` 的 feed，分别
被 `plugin-package-kmod` 与 `plugin-feed-kmods` 拒绝。理由：这块设备的核模块放在每次构建各
一个的目录里（`releases/<version>/kmods/<build hash>/kmods`），为另一个核构建的模块装得上、
然后加载不了。看得见的损失不是那个模块，而是下次换基底之后起不来的那台机器。
`allow-kmod = yes` 是给读过这个代价、并且有理由的人准备的。

`arch = noarch` 是默认值，也是本版本唯一接受的取值。URL 里带架构段的 feed（`/x86_64/`、
`/x86_64_*/`、`/i386_*/`、`/aarch64_*/`、`/arm_*/`、`/mips*/`、`/riscv64*/`）被
`plugin-feed-arch` 拒绝。理由：按架构发布的树是照着那个架构的基底构建的，而本项目只在一个
发布线上出这一个目标。取一棵为别的基底构建的树，正是对齐器与跟随存在的意义所在，所以默认是
拒绝而不是警告。

还有两条更小的边界也在这里：`key` 必须指向 `/etc/apk/keys/` 下确实存在的文件
（`plugin-key-outside`、`plugin-key-missing`），而且没有任何声明能导入一把钥匙。本系统不管理
keyring，插件也没法让它开始管理。

## 源不回答的时候

有三种不同的故障，各有各的答案。

**check 时不回答的 feed** 是一次被拒绝的 check：`plugin=<label> verdict=blocked
reason=feed-unreachable`，退出码 `74`。插件什么都不贡献，`plugins list` 会一直这么说，直到
再 check 一次。

**check 时还好、事务时不可达的 feed** 不会让任何新东西失败。verdict 还是 `ok`，feed 还在
repositories 文件里，apk 从它那儿取不到东西，于是这次事务的结局与「一次没有网络的跟随」历来
的结局完全一样：记录保持 `follow=pending reason=network`，`ab-slot status` 打印那两行让你用
`ab-packages update` 重试，同时往 `/boot/ab/plugins.journal` 追加一行：

```
2026-11-21T03:20:07Z plugin-suspended reason=network
```

这一行只在有插件参与时才写：什么都没声明时，一次失败的跟随根本不会写它。所以它的有无就是
「一次普通的离线跟随」与「一次还欠着插件 feed 的跟随」之间的区别，不必去读 apk 的输出才知道。
写不进去的日志不会让任何事失败：它解释一个决定，它不做决定。

**有插件、但它的 feed 文件建不出来**（有活跃插件而 `/tmp` 不可写）同样不会让任何新东西失败，
而且它不沉默。事务用机器自己的 feed 跑完，`/boot/ab/plugins.journal` 里每次丢掉这套 feed 的 apk
调用各留一行：

```
2026-11-21T03:20:07Z plugin-skip reason=tmp-unwritable
```

只有一条命令是拒绝而不是继续：跟随里的 world prune。缺了声明的 feed，它分不清「这个发布不提供
这个名字」和「插件的 feed 提供」，而凭半个答案删掉一个 world 条目，等于把别人有意装上的包
「取消点名」了——所以它回答 `prune-unanswerable`，一个条目都不删。

这些故障都不写 `/etc/apk/repositories.d`、`distfeeds.list` 或任何 world 条目。插件的 feed
活在 `/tmp` 下那个每次 apk 调用都重新拼一遍的文件里，所以一个消失的来源在机器自己的包状态里
什么都不留——下一次网络正常的事务直接把它再读一遍就是。

## 关掉一个插件

两种办法，任何一种都是完整的：

```
enabled = no                        # 写在 plugin.conf 里
rm -rf /etc/ab/plugins.d/<label>     # 或者删掉整个目录
```

两者都不需要重新 check。`enabled = no` 让插件在下一次 apk 调用时不进入任何事务，删掉的目录
则没有声明可读。`plugins list` 会继续打印被关掉的插件——一行 `enabled=no`——因为「声明了但
关着」和「从来没有过」是两个不同的事实，而后者不是需要修的毛病。

两者都不做的是卸载：那些包是 apk 的，它们留在机器上。删掉目录同时删掉了 verdict，所以以后
再打开这个插件时它是 `checked=never`，在重新 check 之前什么都不贡献。

**world 条目不会随开关一起消失，而有一条路径会把它拿掉。** `apply` 装上的名字留在
`/etc/apk/world` 里，跟随会继续从任何提供它的来源维护它们。真正会删条目的是跟随里的 prune
（`ab_packages_follow`，由新基底的首次启动和 `ab-packages update` 跑）：它删的是**这个发布不
提供**的 world 条目，判断基于一次事务会读的那套 feed。插件关掉之后，那套 feed 里就不再有它的
feed，于是只有这个 feed 提供的包读作「不提供」，条目被删掉——包本身仍然装着、配置也还在，
`apk add <name>`（或一次 revert）就能把条目放回来。这条规则对每一个 world 条目都一样，从来不是
插件专属；这也正是「插件的 feed 不是第二份包状态」的意思：它们决定一个名字从哪来，不决定 world
有没有资格忘掉它。

## 撤销插件装上的东西

插件层不保留自己的任何状态。没有要迁移的东西，没有要回滚的东西，除了那个目录本身也没有要清理
的东西。它装的包就是 world 里普通的 apk 包，用本来就在的包工具撤销（见
[update.zh-CN.md](update.zh-CN.md)）：

| 你想要 | 用 | 它做什么 |
| --- | --- | --- |
| 装之前的那套版本 | `ab-slot packages revert` | 按最新一份快照回放版本。在装某个你也许不留的东西之前先 `ab-slot packages snapshot`，否则没有可以回去的地方 |
| 把留住的体重装一遍 | `ab-packages replay [<file.apk>...]` | 安装 `/etc/apk/ab/local/` 下留住的本体；给它文件时，留住并安装那个文件 |
| 整个上一套系统（含包） | `ab-slot rollback` | 回到另一个槽和它自己的那一层包；跨基底是这个，不是包回退 |

`ab-slot packages snapshot` 记录这台机器，并且（除非给了 `--no-payloads`）把一次 revert 会装的
本体取下来。这次取件读的是跟随读的同一套 feed——插件的 feed 也在里面——所以只有某个声明 feed
提供的包也能在快照里有本体，而不是记一个 `payload-gap`，离线的回退对它们同样存在。

它们都不删除包。从插件装上的包，不会因为插件而以任何「命令能挑出来撤销」的方式被挂住：包上
没有记插件名，同一个包也可能来自任何地方。删掉一个包是 apk 自己的操作——`apk del <name>`，
它先打印计划，而且可能连带删掉依赖它的包——本项目刻意不替你做这件事。

## 一个例子：iStore

iStore 是 OpenWrt 上的第三方应用商店。它在这里出现，是作为一份真实声明的形状，而不是推荐。
**本项目不为 iStore 背书，不测试它，也不在它发布的设备上启用它。** 这个例子是
`enabled = no`，它会一直关着，直到拥有这台机器的人自己打开它、读一遍 verdict，再做决定。
文件留在 [examples/plugins/istore/plugin.conf](examples/plugins/istore/plugin.conf)，由你复制到要装它的
机器的 `/etc/ab/plugins.d/istore/plugin.conf`；**镜像里不带任何插件声明**。

```
/etc/ab/plugins.d/istore/plugin.conf

api = 1
kind = packages
enabled = no
feed = https://istore.istoreos.com/repo-apk/all/store/packages.adb
package = luci-app-store
```

这个地址是 iStore 发布它商店树的形状（`.../repo/all/store`），包名是它的安装器所安装的那个。
两者都不是我们的，都可能变，而本项目没法让它们工作——这正是 `plugins check` 的用途。照抄
之前有两点值得知道：

* feed 必须提供一个这台机器上的 apk 能读的索引。只带旧包格式的树在 check 时回答
  `unverifiable`，然后插件什么都不贡献——这是对「这台机器到底能不能用这个来源」的诚实回答，
  而不是一个装到一半才失败的安装。
* 把架构段写在路径里的镜像（`.../repo/x86_64/...`）在 `arch = noarch` 下会被拒绝。`all`
  那棵树符合护栏，按架构分的那棵不符合，需要本项目出一个接受它的版本。

在一台你坐在它前面的机器上，打开它长这样：

```sh
# 把上面文件里的 enabled 改成 yes，然后：
ab-packages plugins check istore      # 在装任何东西之前，把 verdict 打在屏幕上
ab-packages plugins repos             # 把一次事务会读的文件打在屏幕上
ab-packages plugins apply istore      # 计划块、提问、一次 apk 事务
```

如果那个答案不是你要的，再写回 `enabled = no`，或者删掉目录。这个例子没有什么特别：它只是
众多声明里的一个，上面每一条护栏对它都和对你自己写的插件一样适用。

## reason 表

每一次拒绝只报一个 token，而且这个 token 是稳定的，所以脚本或 runbook 可以拿它做匹配。
`plugins check` 打印 `plugin=<label> verdict=blocked reason=<token>` 并以 `74` 退出；
`plugins apply` 打印 `ab-packages: refused, reason=<token>`，在装任何东西之前以 `74` 退出。

| token | 何时 | 含义 |
| --- | --- | --- |
| `plugin-label-invalid` | 静态 | 目录名不匹配 `[a-z0-9][a-z0-9_-]*` |
| `plugin-conf-missing` | 静态 | 目录在，但没有 `plugin.conf` |
| `plugin-syntax` | 静态 | 有一行不是 `key = value` |
| `plugin-unknown-key` | 静态 | 声明用了本版本没有的键 |
| `plugin-key-duplicate` | 静态 | 只能出现一次的键出现了两次 |
| `plugin-api-unsupported` | 静态 | `api` 缺失，或不是 `1` |
| `plugin-kind-invalid` | 静态 | `kind` 既不是 `source` 也不是 `packages` |
| `plugin-enabled-invalid` | 静态 | `enabled` 既不是 `yes` 也不是 `no` |
| `plugin-no-feed` | 静态 | `kind = source` 却没有 `feed` |
| `plugin-no-package` | 静态 | `kind = packages` 却没有 `package` |
| `plugin-feed-scheme` | 静态 | feed 不是 `http(s)://` 地址，或其中带空白 |
| `plugin-feed-kmods` | 静态 | feed 的 URL 含 `/kmods/`，而 `allow-kmod` 不是 `yes` |
| `plugin-feed-arch` | 静态 | feed 的 URL 带架构段，而 `arch = noarch` |
| `plugin-package-kmod` | 静态 | 包名是 `kmod-*`，而 `allow-kmod` 不是 `yes` |
| `plugin-package-invalid` | 静态 | `package` 的值不是 apk 包名：一个 `-选项`，或者一个值里两个名字 |
| `plugin-key-outside` | 静态 | `key` 不是 `/etc/apk/keys/` 下的路径 |
| `plugin-key-missing` | 静态 | `key` 点名的文件不在 |
| `feed-unreachable` | check | 某个声明的 feed 没有回答 |
| `unverifiable` | check | apk 回答不了，或者是机器上没有取件工具。记成 blocked，绝不记成「没有 shadow」 |
| `shadow:<name>` | check | feed 提供的 `<name>` 版本严格高于基底的 |
| `shadow-allowed` | check | 同上，但 `allow-shadow = yes`。verdict 是 `ok` |
| `verdict-unwritable` | check | check 写不下 `.verdict`；问题答了，但没有东西会读这个答案，命令以非零退出 |
| `plugin-disabled` | check | `enabled = no`；没有取任何东西，也没有写 verdict |
| `plugin-nothing-to-install` | apply | 声明没有点名任何包；退出码 `0`，无事可做 |
| `apk-<rc>` | apply | 事务失败，附带 apk 自己的退出状态 |
| `plugins-lib-missing` | 任意 | 这台机器上没有插件库 |
| `plugins-lib-stale` | 任意 | 这台机器上的包库比命令旧；重装平台层 |
| `plugins-repos-unwritable` | repos、check、apply | repositories 文件写不进 `/tmp` |

## 这套东西不做什么

不在范围内的事和在场的事一样刻意：

* **没有代码。** 插件不能挂到启动、安装、健康检查或升级步骤上。这个想法的下一层——文件与
  钩子——不在本版本里，这里也没有任何地方假装它们在。
* **不处理插件之间的依赖。** 没有排序、没有版本约束、没有「插件 B 需要插件 A」。apk 只解它
  拿到的那一次事务；需要别人的插件，就是一份把自己的需求写成包的声明。
* **没有信任链。** `key` 只检查存在。本项目不导入签名钥匙、不校验 feed 的签名，HTTPS 是一个
  feed 唯一的保证。
* **没有目录，也没有市场。** 插件是你自己写或抄来的文件，label 是你自己起的。没有远程清单、
  没有搜索、没有 GUI。
* **不编辑机器自己的 feed 文件。** `/etc/apk/repositories.d` 与 `distfeeds.list` 只读不写；
  `plugins apply` 不写 `/boot/ab/packages`。包状态里唯一会动的是 world，而动手的不是这条路径：
  `plugins apply` 跑的是一次 apk 事务，apk 会把它装上的名字记进 `/etc/apk/world`，和手敲一次
  `apk add` 完全一样。
* **不偷偷联网。** 只有 `check` 取东西，`apply` 只跑一次坐在机器前面的人要求的事务。

关于包跟随、它发布的记录、以及一次包改动怎么回去，见 [update.zh-CN.md](update.zh-CN.md)。
机器出毛病时先读什么，见 [troubleshooting.zh-CN.md](troubleshooting.zh-CN.md)。

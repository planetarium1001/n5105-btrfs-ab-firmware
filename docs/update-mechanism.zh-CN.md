# 更新机制参考

[English](update-mechanism.md) | [中文](update-mechanism.zh-CN.md)

更新机制发布的每一个状态字段：取值、含义、写入者，以及在机器上核对它的命令。本页面向维护者
与高级用户，只做查阅；操作步骤在 [install.md](install.md) 与 [update.md](update.md)。

## 前置条件

这里的命令都在设备上以 root 身份、在某个已启动的槽位（slot）里执行。本页谈到的每个事实都
落在四处之一，验证一个字段就是去读它所在的那一处：

- `/boot/ab/state.json` —— 槽位状态，唯一的真相来源
- `/boot/ab/packages` —— 上一次升级发布的一行包记录
- `/boot/ab/log/` —— 环日志，用 `ab-slot log` 打印
- `/proc/cmdline` 与 `/proc/mounts` —— 这次启动来自哪个槽位，以及当前挂载了什么

下文的 `<slot>` 是 `a` 或 `b`，`<version>` 是形如 `25.12.2` 的上游版本，`<layer>` 是可写层
名，即 `@overlay-<version>`；同一版本第二次使用时追加 `-r<N>`。

## 分层

有四样东西承载整棵树：每个槽位的两个只读子卷——基底（base）与平台层（platform）、p4 上的
一个可写层（writable layer），以及这些子卷安装所用的载荷（payload）。p4 上还有三个用户子卷，
它们在树之外，回滚不会动它们。

```text
 p1  ESP (vfat)     ab/state.json  ab/packages  ab/log/  ab/device.json
                    boot/grub/ab-slot.cfg  vmlinuz-a|b  initrd-a|b

 p2  slot a         @sys        基底 rootfs，只读
     (btrfs)        @platform   本项目的平台层，只读
 p3  slot b         @sys        同一对子卷，比另一个槽位旧或新一次更新
     (btrfs)        @platform

 p4  data (btrfs)   @overlay-<version>  upper/ = 运行根的每一次写
                    @data /data   @docker /opt/docker   @swap /swap

 运行根 = overlay(lowerdir = 运行槽位的 @platform:@sys,
                  upperdir = @overlay-<version>/upper)
```

| 层 | 承载什么 | 可写 | 由谁写 | 回滚时一起动吗 |
| --- | --- | --- | --- | --- |
| 基底（`@sys`） | 逐字节一致的上游 rootfs | 否 | 仅由一次更新 | 是 |
| 平台层（`@platform`） | `ab-slot`、`ab-upgrade`、init.d 钩子 | 否 | 仅由一次更新 | 是 |
| 载荷 | 一次更新所安装的那些文件 | 否 | 发布者 | 不适用 |
| 用户层（`@overlay-<version>/upper`） | `/etc/config`、`/etc/apk/world`、已安装的包 | 是 | 运行中的系统 | 是 |
| `/data`、`/opt/docker`、`/swap` | 用户文件、容器状态、swap | 是 | 用户 | 否 |

来源：`docs/boot-overlay.md` 的层职责与 p4 子卷一节，`docs/partitions.md`。

### 载荷里有什么

载荷是一个 tar，成员旁边放一份 manifest；写任何东西之前，每个成员都要按 manifest 里的
摘要核对一遍。

| 成员 | 是否必需 | 更新拿它做什么 |
| --- | --- | --- |
| `manifest.json` | 是 | `format`、`rootfs`、`platform`，以及每个成员一个 `sha256` 块 |
| `rootfs.tar.gz` | 是 | 解到目标槽位的 `@sys` 上 |
| `kernel.bin` | 是 | 复制到 `/boot/vmlinuz-<slot>` |
| `initramfs.cpio.gz` | 是 | 复制到 `/boot/initrd-<slot>` |
| `platform.tar` | 是 | 解到目标槽位的 `@platform` 上 |
| `boot.tar` | 可选；带 `--bootloader` 运行时必需 | 走 ESP 的分阶段写入，被替换的菜单留作 `grub.cfg.prev` |

来源：`platform/usr/sbin/ab-upgrade` 的成员表与摘要循环，
`platform/lib/upgrade/platform.sh` 的槽位写入。

### 用户状态的位置

有三处存放用户自己的状态，它们的区别在于什么操作能把它们恢复回去。

- `/etc/config` 以及合成根下其它被编辑过的文件都在 `upper/` 里，因此随可写层走，随槽位一起
  回滚。
- `/etc/apk/world`、apk 数据库与 `/etc/apk/ab/local/` 也在同一层，原因相同：保留下来的包体
  存放在可写层，绝不在 `/data`。
- `/data` 与 `/opt/docker` 是独立子卷。更新和回滚都不写那里。

来源：`platform/lib/upgrade/packages.sh` 的包体保留区，`docs/boot-overlay.md`。

## 槽位状态机

两个槽位交替使用。`ab/state.json` 指明哪个槽位是已提交、哪个是候选。每次状态迁移都是对这个
文件的一次原子改名，随后重建 GRUB 读取的提示文件（hint）。编号 `generation`（世代）只增不减，
用来给可写层排序。

```text
 committed=a, pending=none      GRUB: default=a, fallback=a
        |
        |  ab-upgrade <payload>          就地写入槽位 b
        |  ab-slot layer b <ver> <layer> 世代 + 1，更新 b 的版本与可写层
        |  ab-slot pending b             pending=b，候选标记被清掉
        v
 committed=a, pending=b         GRUB: default=b, fallback=a
        |
        |  重启；GRUB 传入 ab.slot=b；ab-boot 按状态文件修复提示文件
        v
 候选槽位 b 启动                 ab-boot 把这次启动记为候选，attempt=<n>
        |
        |  ab-commit，预算 150 秒：三项探针
        |
        +-- 全部通过 ------> ab-slot commit b    committed=b, pending=none
        |
        +-- 有一项失败 ----> ab-slot abandon     committed=a, pending=none，重启回 a
        |
        +-- 启动中断 ------> initramfs 的兜底放弃，或尝试计数达到
                             AB_BOOT_RETRY_MAX（1），下一次启动以
                             result=abandon reason=attempt-limit 放弃
```

来源：`platform/usr/sbin/ab-slot` 的状态命令、`platform/etc/init.d/ab-boot`、
`platform/etc/init.d/ab-commit`、`initramfs/lib/wf.sh`。

## 状态文件

`ab/state.json` 是真相，`boot/grub/ab-slot.cfg` 是 GRUB 能读的提示文件。提示文件只有两条
命令，`fallback` 在前，因此写到一半被打断时仍然会落回已提交槽位。它写的是菜单条目序号而不是
槽位字母：槽位 `a` 是条目 `0`，槽位 `b` 是条目 `1`。

| 字段 | 取值 | 含义 |
| --- | --- | --- |
| `generation` | 整数，只增不减 | 为回收排序可写层；不给任何一层命名 |
| `committed` | `a` \| `b` | 机器已提交运行的槽位 |
| `pending` | `a` \| `b` \| `null` | 下次启动尝试的候选槽位，没有则是 `null` |
| `slots.<a\|b>.rootfs` | `<version>` | 该槽位承载的上游版本 |
| `slots.<a\|b>.upper` | `<layer>` | 该槽位启动时使用的可写层 |

`generation` 只在 `ab-slot layer` 里变动，而更新在铺一个槽位时调用的正是它。`pending`、
`commit`、`abandon` 与 `rollback` 只重写文件，不动这个数字。

来源：`platform/usr/sbin/ab-slot` 的状态读取与 `write_state`、`cmd_layer`。

## 健康检查与回滚判据

三项探针在 `done` 之后、同一次启动内、150 秒预算里跑完。三项必须全部通过，候选槽位才会被提交。

| 探针 | 通过条件 |
| --- | --- |
| `overlay-writable` | 合成根 `/` 可写，且至少剩 16 MiB |
| `fw4-present` | nft 规则集非空，且存在 `inet fw4` 表 |
| `wan-present` | `network.wan` 指名的设备存在 |

失败不做修补：候选槽位被放弃，`pending` 被清空，提示文件指回已提交槽位，机器重启进入它。

来源：`docs/lifecycle.md` 的健康检查一节，`platform/etc/init.d/ab-commit`。

## 字段表

`ab-slot status` 在 stdout 打印一行机器可读的字段，在 stderr 打印给人看的摘要，因此
`ab-slot status 2>/dev/null` 得到的只是那一行。字段顺序固定，末尾的包相关字段只在
`/boot/ab/packages` 存在时出现。

| 字段 | 取值 | 含义 | 机器上的验证命令 |
| --- | --- | --- | --- |
| `slot=` | `a` \| `b` | 这次启动运行的槽位，取自内核命令行上的 `ab.slot=`；没有时取已提交槽位 | `grep -o 'ab.slot=[ab]' /proc/cmdline` |
| `upper=` | `<layer>` | 运行槽位的可写层 | `cat /boot/ab/state.json` 与 `btrfs subvolume list /mnt/p4` |
| `generation=` | 整数 | 可写层的排序号 | `cat /boot/ab/state.json` |
| `committed=` | `a` \| `b` | 状态文件认定的已提交槽位 | `cat /boot/ab/state.json` |
| `pending=` | `a` \| `b` \| `none` | 下次启动要尝试的候选槽位 | `cat /boot/ab/state.json` |
| `p4=` | `ok` \| `degraded` | `/mnt/p4` 是否已挂载 | `awk '$2=="/mnt/p4"' /proc/mounts` |
| `data=` | `ok` \| `missing` | `/data` 是否已挂载 | `awk '$2=="/data"' /proc/mounts` |
| `docker=` | `ok` \| `missing` | `/opt/docker` 是否已挂载 | `awk '$2=="/opt/docker"' /proc/mounts` |
| `swap=` | `ok` \| `missing` | `/swap` 是否已挂载 | `awk '$2=="/swap"' /proc/mounts` |
| `next=` | `a` \| `b` \| `unknown` | GRUB 下次会启动哪个槽位，从提示文件回读 | `ab-slot next` |
| `disk=` | 设备节点，或 `unknown` | 这台机器从哪块盘启动 | `ab-slot log \| grep stage=device` |
| `method=` | `cmdline` \| `partuuid` \| `partname` \| `mount` \| `unique` \| `unresolved` \| `unavailable` | 那块盘是怎么确定的 | 同一条 `stage=device` 行 |
| `boot=` | `ok` \| `degraded` \| `unknown` | 这次启动是怎么起来的，读本次启动的环日志 | `ab-slot log \| grep stage=boot` |
| `esp=` | `ok` \| `dirty` \| `unreadable` \| `unknown` | initramfs 对它挂载的那个 ESP 的判断 | `ab-slot log \| grep stage=esp-health` |
| `packages=` | `aligned` \| `limited` \| `followed` \| `unknown` | 该槽位的包元数据是否描述了它正在跑的基底 | `cat /boot/ab/packages` |
| `packages_reason=` | 一个对齐器的 token、`none`、`no-record`、`other-slot`、`unknown` | 该判定为什么是这样 | `cat /boot/ab/packages` |
| `follow=` | `pending` \| `followed` \| `failed` \| `abandoned` \| `never` \| `unknown` | 包是否真的被搬到了这个基底上 | `ab-packages status` |
| `reason=` | `none`、`network`、`timeout`、`no-evidence`、`apk-<rc>`、`no-world`、`no-apk`、`no-packages`、`feeds-rewritten`、`no-record`、`other-slot`、`unknown` | 上一次跟随尝试为什么这样结束 | `ab-packages status` |
| `hint=` | `ab-packages update` \| `none` | 重试跟随要跑的命令 | `sed -n 's/^.* hint=//p' /boot/ab/packages` |

有三个值是机器没有证据就不该声称的，因此它们宁可报 `unknown`，也不报一个让人安心的默认值：
`boot=`、`esp=`、`packages=`。

来源：`platform/usr/sbin/ab-slot` 的 `cmd_status` 及其上方那些字段读取函数。

### 在脚本里读一个字段

一个函数就能读这一行的大部分字段。`^` 锚点是有用的：没有它，`reason=` 也会匹配到
`packages_reason=`。

```sh
ab-field() { ab-slot status 2>/dev/null | tr ' ' '\n' | sed -n "s/^$1=//p"; }
ab-field pending
ab-field follow
```

`hint=` 的值里带一个空格，因为它是一条命令，所以它是记录里的最后一个字段，并有自己的读法：

```sh
sed -n 's/^.* hint=//p' /boot/ab/packages
```

取某个槽位的版本有它自己的命令，完全不读状态行：

```sh
ab-slot rootfs a
ab-slot rootfs b
```

## 包跟随

更新替换的是系统树，而装在它下面的包是按旧基底构建的。对齐元数据是离线的、机械的。真正把包
搬过去（follow，跟随）是另一笔事务，它需要网络或者一次预取。

有四件事会启动跟随。其中三件读同一个记录字段 `follow=pending`；升级则按自己那个问题的回答决定。

| 触发时机 | 由谁发起 | 由什么决定 |
| --- | --- | --- |
| 升级过程中，切换之前 | `ab-upgrade` 跑闸门（gate）、问一次，然后预取 | 计划块与对它的回答 |
| 新基底的首次启动 | `ab-boot` 派生一个 worker | 记录里这个槽位的 `follow=pending` |
| 一次 `ifup` | ifup hotplug 钩子，尝试一次 | 同一个记录，以及单实例锁 |
| 由人发起 | `ab-packages update` | 同一个记录；闸门与计划会重跑 |

启动路径既不等跟随，也不跑 `apk`。同一时刻只有一个 worker，锁在
`/var/lock/ab-packages-follow.lock`。

来源：`platform/etc/init.d/ab-boot`、`platform/etc/hotplug.d/iface/90-ab-packages`、
`platform/lib/ab-net-probe.sh`、`platform/usr/sbin/ab-packages`。

## 预取与离线应用

下载发生在切换之前，机器还在跑一个能用的槽位。求解器说明哪些包会动，只把这些取进新槽位自己
的缓存，即将被启动那一层里的 `/etc/apk/ab/cache/`。

```sh
apk --cache-dir /etc/apk/ab/cache --cache-max-age 100000 \
    add --virtual .ab-follow --allow-untrusted --force-non-repository \
    /etc/apk/ab/cache/*.apk
apk del .ab-follow
```

缓存里有包体时，首次启动跑的就是这几条，而且完全不需要网络。预取失败不是升级失败：记录回落到
`follow=pending reason=network`，由下面的重试阶梯接手。

| 阶梯 | worker 何时重试 |
| --- | --- |
| W1 | worker 启动后第 0、15、30、60、120、300 秒 |
| W2 | 每次 `ifup` 一次 |
| W3 | 每 1800 秒一次，直到启动后 86400 秒，然后 `follow=abandoned` |

来源：`platform/lib/upgrade/packages.sh` 的预取与离线跟随，
`platform/lib/ab-net-probe.sh` 的阶梯。

## 记录字段：packages= 与 follow=

`packages=` 描述元数据，`follow=` 描述包本身。两者发布在同一行，因此读一次就能把「元数据
对上了这个基底」和「包已经被搬上去了」区分开。

| 事件 | `packages=` | `follow=` | `reason=` |
| --- | --- | --- | --- |
| 切换之前对齐器成功 | `aligned` | `pending` | `none` 或 `feeds-rewritten` |
| 用户回答了 `--system-only` | 不变 | `never` | `none` |
| 预取取到了包体 | `aligned` | `pending`，带 `cache=<bytes>` | `none` |
| 预取跑不起来，或 feed 没有回应 | `aligned` | `pending` | `network` |
| 首次启动找不到可用网络 | `aligned` | `pending` | `network` |
| 事务搬动了包 | `followed` | `followed` | `none` |
| world 本来就是最新的 | `followed` | `followed`，`upgraded=0` | `none` |
| 事务失败，或把该做的全跳过了 | 不变 | `failed` | `apk-<rc>`、`timeout`、`no-evidence` |
| 24 小时没有可用 feed | 不变 | `abandoned` | `network` |

来源：`platform/lib/upgrade/packages.sh` 的记录发布与跟随引擎。

## 剪枝的两道闸门

跨版本移动可能留下一条新基底的 feed 不再提供的 `world` 条目，而这样一条条目会让之后每一次
apk 事务都解不出来。剪枝（prune）只删掉那条条目，其它一切保留：包仍是已安装状态，文件仍在，
`/etc/config` 与 `/data` 绝不被碰到。

删任何东西之前，两道互相独立的闸门都必须给出答案。

| 闸门 | 判据 | 不通过时的拒绝 |
| --- | --- | --- |
| 索引已刷新 | 调用方报告它的 `apk update` 成功 | `index-stale`，什么都不删 |
| 索引至少能回答 | `apk search` 能答出 world 里没有提到的一个探针名 | `index-unusable`，什么都不删 |

第二道闸门把「这个发行版没有这个包」和「索引读不出来」分开。一个答不出任何东西的索引对所有名字
都答「没有」，照那个答案删掉整个 world 就是伪装成诊断的批量删除。

通过两道闸门的候选还要再对着索引确认一次：feed 确实提供的名字是版本已经下架的 pin，而不是这个
发行版缺少的包，那条条目会被保留。

| 报在哪 | 说什么 |
| --- | --- |
| 环日志里的 `stage=packages-prune` | `dropped=<n>` 与那些名字 |
| 记录里的 `world_dropped=` | 数量，由 refresh 路径写入 |
| `ab-slot status` 的人类摘要 | 数量，从 `world_dropped=` 回读 |

来源：`platform/lib/upgrade/packages.sh` 的剪枝，`platform/lib/ab-net-probe.sh` 的 worker。

## 闸门与失败语义

有三种结果容易混淆：升级被拒绝、判定降为 `limited`、出现 GAP。它们发生在不同时刻，代价也不同。

### 什么情况拒绝升级

拒绝发生在写入任何东西之前，退出码 `74`，机器保持原样。每一个 token 都列在
[update.md](update.md) 里；类别是：

- 这台机器不是合法目标 —— `writable-layer-degraded`、低于 5 个百分点的 `low-space-<n>pct`、
  `slot-status-failed`、`platform-layer-shadowed`、`payload-already-installed`
- 载荷对自己的描述不一致 —— `manifest-*`、`member-missing-*`、`digest-mismatch-*`、
  `initramfs-mixed-module-vermagic-<n>`
- feed 的回答不可用 —— 各类 `feed-*` token，从配置一直到摘要不匹配

包闸门被 blocked 并不会拒绝升级。它把问题里提供的包数置为 0，系统照旧切换。

来源：`platform/usr/sbin/ab-upgrade` 各处拒绝点，`docs/update.md`。

### 什么情况降级为 limited

`packages=limited` 意味着元数据没能改成描述这个槽位现在跑的基底。切换不被阻断：机器照常启动、
照常运行，只是在元数据修好之前装不上针对这个内核构建的包。

| 写入者 | `packages_reason=` 里的 token |
| --- | --- |
| 对齐器的调用方，新层里缺 `packages.sh` 时 | `packages-lib-missing` |
| 对齐器返回非零 | 对齐器自己的 token，例如 `world-unwritable`、`distfeeds-unwritable`、`world-not-verified` |
| 已退役的 refresh 路径，仅在库没有暴露跟随入口时 | `feeds-stale`、`pruned`、`refresh-failed`、`partial` |

除 `aligned` 与 `followed` 之外，`ab-slot packages upgrade` 一律拒绝，这道闸门保证包事务
不会发生在元数据过期的槽位上。

来源：`platform/lib/upgrade/platform.sh` 的对齐阶段，`platform/lib/upgrade/packages.sh`。

### 什么是 GAP

闸门只回答三种状态。`ok` 与 `blocked` 说的是跟随能不能跑起来；`gap` 说的是能跑，而 world 里有
一部分动不了。

| 状态 | 原因 | 含义 |
| --- | --- | --- |
| `ok` | `none` | world 里每条条目都能跟随 |
| `blocked` | `pin-mismatch`、`unsolvable`、`unreachable` | 跟随跑不了；升级照旧进行 |
| `gap` | `none`、`no-world`、`no-apk`、`no-tmp`、`no-feeds` | 跟随会跑，被点名的那些条目留在原地 |

GAP 挡下的每条条目都带一个归因 token，计划块与记录用的是同一套词：`local`（NO COPY）、
`stale-abi`（ABI STALE）、`gone`（DROPPED）、`pinned`（PINNED）、`unreachable`
（UNREACHABLE）。

来源：`platform/lib/upgrade/packages.sh` 的闸门，`platform/lib/ab-plan.sh` 的显示词。

## 排障入口

每个现象都指向第一个能回答它的命令。日志行里的 `reason=` token 就是写报告时该引用的那个 token。

| 现象 | 第一条命令 | 它告诉你什么 |
| --- | --- | --- |
| 升级退出 `74` | 打印出来的 `reason=` 行，运行被存进升级日志时再用 `ab-slot log --upgrade` | 哪一项检查拒绝了，以及什么都没写 |
| 升级后机器又回到旧槽位 | `ab-slot log --prev` | `stage=abandon result=fail reason=healthcheck-failed detail=<probe>` 点名失败的那项探针 |
| 启动过的槽位始终没有提交 | `ab-slot log \| grep -E 'probe=\|stage=commit\|stage=abandon'` | 哪项探针失败，或者提交本身失败 |
| `next=` 不是你以为的槽位 | `ab-slot next` 与 `ab-slot next --write` | 提示文件过期了；日志里的 `stage=slot-cfg` 显示写进去了什么 |
| `follow=` 一直是 `pending` | `ab-packages status` 与 `ab-slot log \| grep stage=packages-refresh` | 走到哪一级阶梯、探针的判断，以及上一次尝试的原因 |
| `follow=failed` | `ab-packages status`，然后 `ab-packages update` | 原因 token；`apk-<rc>` 表示事务本身失败了 |
| `packages=limited` | `cat /boot/ab/packages` | 对齐器的 token；下一次升级会重写元数据 |
| `packages_reason=` 是 `other-slot`，或 `packages=`、`follow=` 是 `unknown` | `ab-slot status` 与 `cat /boot/ab/packages` | 记录描述的是另一个槽位，或没有槽位；下一次升级或回滚会重新指向 |
| 可写分区快满了 | `df -h /mnt/p4` 与 `ab-slot gc --dry-run` | 哪些层没有引用、会被回收 |
| `disk=unknown` | `ab-slot log \| grep stage=device` | 失败的那一级解析；输入是 `ab/device.json` 与 GPT 名字 |
| `boot=degraded` | `ab-slot log`，然后 [install.md](install.md) 的降级一节 | 可写层是 tmpfs，这次启动写下的东西活不过重启 |
| `esp=dirty` 或 `esp=unreadable` | `ab-slot log \| grep stage=esp-health` | initramfs 在挂载之前就判断了 ESP；启动照旧继续 |

## 进一步阅读

- [update.md](update.md) —— feed、风险级别、每一个拒绝 token 与退出码
- [install.md](install.md) —— 写盘、首次启动、抢救写坏的引导器
- [lifecycle.md](lifecycle.md) —— 更新事务、回收、环日志格式
- [boot-overlay.md](boot-overlay.md) —— 引导链与分层根
- [partitions.md](partitions.md) —— 四个分区及其上的子卷
- [conflicts-payload.md](conflicts-payload.md) —— 冲突检测与载荷契约

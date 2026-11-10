# 安装与升级

这篇是运维视角：怎么把镜像写到盘上、首次启动要看什么、运行中的系统怎么升级、出问题怎么退回去。设计细节见
[partitions.md](partitions.md)、[boot-overlay.md](boot-overlay.md) 与
[lifecycle.md](lifecycle.md)。

## 需要准备什么

一个发布目录里有四个文件：

| 文件 | 用途 |
| --- | --- |
| `n5105-ab-<platform>-<upstream>.img.gz` | 完整磁盘镜像，每台机器写一次 |
| `n5105-ab-<platform>-<upstream>.tar` | 升级载荷，供 `ab-upgrade` 使用 |
| `SHA256SUMS` | 上面两个文件的摘要 |
| `release-notes.md` | 版本、上游输入与本次构建的验收判据行 |

写盘之前先校验：

```sh
sha256sum -c SHA256SUMS
```

镜像是普通 GPT 布局：一个 EFI 系统分区、两个槽文件系统、一个存放可写层的共享 btrfs 分区。只支持 x86-64 UEFI
启动，不支持传统 BIOS。目标机器需要 N5105 v5 的板型与四分区布局，或者任何一台你想用来测试的 x86-64 机器，因为镜像本身是自包含的。

## 写入镜像

写镜像会毁掉目标盘上的全部内容。先确认盘符，再写：

```sh
lsblk -o NAME,SIZE,MODEL
gunzip -c n5105-ab-<platform>-<upstream>.img.gz | sudo dd of=/dev/nvme0n1 bs=4M status=progress conv=fsync
sudo sync
```

结果是 514 MiB、四个 128 MiB 分区。其余都不用手工创建：ESP 上带着两个槽各自的内核与 initramfs，引导配置已经按已提交槽渲染好，
两个槽的文件系统也各带一份相同的根文件系统。

想写到文件里做虚拟机测试：

```sh
gunzip -c n5105-ab-<platform>-<upstream>.img.gz > test.img
qemu-system-x86_64 -machine q35 -m 1G -bios /usr/share/OVMF/OVMF_CODE.fd \
  -drive file=test.img,if=virtio,format=raw -netdev user,id=n0 \
  -device virtio-net-pci,netdev=n0 -nographic
```

## 首次启动

机器从 ESP 启动，initramfs 用 overlayfs 组合出根，再切到真实系统。一分钟内健康检查跑完，运行中的槽被提交。先看控制台，
再确认状态：

```sh
ab-slot status
```

健康机器只打印一行：

```
slot=a upper=@overlay-<version> generation=1 committed=a pending=none p4=ok data=ok docker=ok swap=ok next=a disk=/dev/nvme0n1 method=partuuid
```

`p4=ok` 表示可写分区已挂载，`data`、`docker`、`swap` 是平台层挂载在它上面的三个子卷。`next=a` 是 GRUB
下次会启动的槽，从 `boot/grub/ab-slot.cfg` 读回；想知道"重启会发生什么"就看这一个字段。如果 `p4` 显示
`p4=degraded`，先读下面的降级小节，再做别的事。

## 验收清单

在把机器交出去之前逐条跑一遍：

| 检查项 | 命令 | 期望 |
| --- | --- | --- |
| 布局完好 | `ab-slot status` | 一行输出，`p4=ok`，有已提交槽 |
| 本次启动被记录 | `ab-slot log` | 有 `stage=boot`、`stage=btrfs-check result=ok`、`stage=commit` |
| 扩容有结论 | `ab-slot log` | `stage=grow result=done`（运行期补做完则是 `stage=resize result=ok`） |
| 工具可用 | `btrfs --version` | 打印 `btrfs-progs` 版本行 |
| 可写层可见 | `btrfs subvolume list /mnt/p4` | 包含 `ab-slot status` 报告的那一层 |
| 防火墙已加载 | `nft list table inet fw4` | 有表，不是报错 |
| 网络已就绪 | `ip -brief address` | 存在 `network.wan` 引用的设备 |
| 回收无事可做 | `ab-slot gc --dry-run` | 没有层被列为待删 |
| 备槽完好 | `ab-slot pending b` 再 `ab-slot abandon` | 前者成功，后者清空 |
| 下次启动符合预期 | `ab-slot next` | 上面那次 abandon 之后是 `next=<已提交槽>` |

最后一行的意义：`ab-slot pending` 会拒绝内核或 initramfs 不在 ESP 上的槽，所以这一步失败说明的是备份槽的载荷缺失，
而不是当前运行的槽有问题。

## 升级运行中的系统

升级写入非活动槽并把它标记为待验证，全程不碰运行中的槽，所以出问题机器照样能用。

```sh
ab-upgrade /root/n5105-ab-<platform>-<upstream>.tar
ab-slot status
ab-slot conflicts
```

`ab-upgrade` 在写入之前完成校验：manifest 形状、逐成员摘要、initramfs 里所有模块是否来自同一次内核构建、可写分区余量、
以及冲突报告。拒绝时退出状态为 74 且什么都不写。成功后状态里另一个槽变成 `pending`，`ab-slot status` 的
`next=` 也会指向它，下次启动会试它：

* 启动后对新槽跑健康检查；
* 全部探针通过则提交该槽，机器留在新槽上；
* 任一探针失败则放弃待验证槽，重启回到已提交槽；
* 新槽在 boot initramfs 阶段就失败时，失败路径会自己清掉 `pending` 再关机（日志里
  `action=fail-safe-abandon`），下次启动回到已提交槽，而不是反复重试那个坏槽。

如果槽已经暂存好、但 `boot/grub/ab-slot.cfg` 没指向它，升级会以 `reason=next-boot-not-<槽>` 失败：
少了这个文件机器会一直启动旧槽，升级永远试不到。

载荷和你都改动过的文件会列在 `ab-slot conflicts` 里。它们从不阻断升级：载荷照样写入新文件，报告告诉你该看哪几个。

## 回退

回退就是提交另一个槽，它仍然保有旧的文件系统与自己的可写层：

```sh
ab-slot rollback
reboot
```

启动后机器落在另一个槽并提交它。这是升级出问题后最快的回头路。它不是恢复出厂：升级以后写入的用户数据留在被推进的那一层里，
只要还有槽引用它，`ab-slot gc` 就不会删它。

只想丢弃已暂存的升级而不启动它：

```sh
ab-slot abandon
```

## 可写分区降级时

共享分区挂不上时启动不会失败：upper 层移到内存，系统照常起来，控制台与 `ab-slot status` 都会显示 `p4=degraded`。
机器能用，但本次启动之后写入的东西重启就没了，而且 `ab-upgrade` 会拒绝执行：

```
ab-upgrade: refused, reason=writable-layer-degraded
```

把这当成硬件警告处理。用 live 系统跑 `btrfs check` 检查盘，备份还需要的东西，原因排除后重新刷镜像。

## 排查

先读启动日志，它用 `key=value` 记录了每个阶段：

```sh
ab-slot log
ab-slot log --prev
```

| 现象 | 通常意味着 | 处理 |
| --- | --- | --- |
| 控制台完全没有输出 | 启动方式或盘不对 | 只用 UEFI 启动，检查磁盘顺序 |
| `p4=degraded` | 共享分区挂不上 | 见上一节 |
| `p4=ok` 但没有 `stage=commit` | 健康检查失败 | `ab-slot log` 会指出失败的探针；待验证槽用 `ab-slot abandon` 清掉 |
| `ab-upgrade` 退出 74 | 载荷或机器状态被拒绝 | 原因既打印也进日志；没有写入任何东西 |
| 升级后仍重启回原来的槽 | 新槽健康检查没过 | 日志里有 `reason=healthcheck-failed`；修好载荷再装一次 |
| `next=` 不是预期的槽 | 引导提示没写成功，或被更早的启动留旧了 | `ab-slot next --write` 按 `ab/state.json` 重写它；日志里 `stage=slot-cfg` 记着写入了哪个值 |
| 升级后总回到已提交槽 | 候选槽在进入用户态前就失败了 | 日志里有 `action=fail-safe-abandon` 与 `reason=`；此时已没有 pending，修好原因后重新安装载荷 |
| `ab-slot status` 显示 `disk=unknown` | 引导盘无法被识别 | 日志里 `stage=device` 会写明；对照实际写入的盘检查 GPT 名称与 `ab/device.json` |
| 出现 `state is locked by another process` | 有写入者在持锁时死掉 | 只要写下这把锁的那次启动（或它的进程）已不存在，锁会被自动接管，环形日志里出现 `stage=lock action=stale-lock-taken`；同一次启动内仍然活着的写入者属于真的并发，照旧拒绝 |
| 出现 `stage=resize result=fail:btrfs-resize` | 文件系统没扩成功（initramfs 里或运行期再次失败） | `ab/log/resize.log` 里有 btrfs 自己的报错；分区保持原尺寸，下一次启动重试 |
| 日志里没有 `btrfs=ok` | 平台层丢了工具 | 重新刷镜像，工具随平台层发布 |

每次失败都会在日志里留一个 `reason=` 记号，和 CI 判据行用的是同一套记号，所以机器上的现象与构建结果可以直接对照，不用猜。

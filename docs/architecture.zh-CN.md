# 架构

**中文** | [English](architecture.md)

一块盘、四个分区、两个可启动槽位、一个共享的可写分区。本文描述这套结构：分区几何、
分区上的文件系统与子卷、组装运行根的启动链、A/B 切换背后的槽位状态机，以及升级所用的
payload 契约。

改启动路径、分区布局、状态文件或 payload 格式之前先读本文。这里写下的每个阈值、日志字段
与契约都由 `scripts/check_design.py` 断言；改一项就要在同一次提交里改对应检查。

## 分区布局

单盘、GPT、仅 UEFI。两个独立的系统槽位，一个承载全部可写状态的分区：

| 分区 | GPT PARTNAME | LABEL | 大小 | 文件系统 | 内容 |
|---|---|---|---|---|---|
| p1 | `ab-esp` | `ESP` | 128 MiB | vfat | GRUB、启动菜单、`vmlinuz-a/b`、`initrd-a/b`、`ab/` 状态、`ab/log/`、`ab/device.json` |
| p2 | `ab-slot-a` | `slot-a` | 128 MiB | btrfs | `@sys`、`@platform` |
| p3 | `ab-slot-b` | `slot-b` | 128 MiB | btrfs | `@sys`、`@platform` |
| p4 | `ab-data` | `data` | 128 MiB | btrfs | `@overlay-<version>`、`@docker`、`@swap`、`@data` |

没有 p128（EF02），也没有传统 BIOS 启动路径。p4 出厂 128 MiB，首启时扩到磁盘末尾；
p1 到 p3 从不移动。

### 每个分区两个名字

| 名字集 | 取值 | 依赖它的一方 |
|---|---|---|
| GPT PARTNAME | `ab-esp`、`ab-slot-a`、`ab-slot-b`、`ab-data` | 启动代码，与 `/sys/class/block/*/uevent` 比对 |
| 文件系统 LABEL | `ESP`、`slot-a`、`slot-b`、`data` | 人，以及镜像阶段里 `blkid` / `lsblk` 的断言 |

PARTNAME 保留 `ab-` 前缀，因为磁盘发现要遍历机器上每个块设备：一个裸的 `data` 或 `esp`
迟早会匹配到无关磁盘并挂载错分区。四条代码路径解析这些名字（`initramfs/boot/init`、
`/etc/init.d/ab-boot`、`/etc/init.d/ab-commit`、`lib/upgrade/platform.sh`），各自在没有
PARTNAME 匹配时回退到 1/2/3/4 的顺序，所以漏改一个名字会藏在回退里而不是在启动时失败。
LABEL 不带版本：`@overlay-<version>`、`/etc/platform-release` 与 `ab/state.json` 已经
是版本的三处权威位置，每次发布都改标签会多一次可能被断电打断的超级块写入。

p1 只存数据，绝不存放可执行脚本：FAT32 没有权限位和符号链接，没有日志，且放在 ESP 上的
脚本不会随槽位一起回滚。

### 容量

实测基线，x86-64 上的 ImmortalWrt 25.12.2：

| 项目 | 数值 |
|---|---|
| `rootfs.tar.gz` | 10.1 MiB |
| 解包后 rootfs | 26.9 MiB，1078 个文件 |
| 4K 块占用 | 31 MiB |
| `zstd:6` 压缩后 | 10.3 MiB |
| `generic-kernel.bin` | 7.35 MiB |

- **p1 = 128 MiB。** 内容峰值约 27 MiB（引导器 3–6 MiB、两个内核 15 MiB、两个 initrd
  4–6 MiB、状态与日志不到 1 MiB），余量约 4 倍。p1 内容达到 64 MiB 时构建失败。
- **p2 = p3 = 128 MiB。** 是解包 rootfs 的 4.7 倍、`zstd:6` 体积的 12 倍；按 2 的幂对齐，
  比例便于核对；运行时只读，仅在升级时写入。
- **p4 = 镜像里 128 MiB，首启后为磁盘剩余空间。** 镜像是 514 MiB：1 MiB 对齐、四个
  128 MiB 分区、末尾 1 MiB 留给备份 GPT。128 MiB 是让可写层可用的下限：把一个 20 MiB 的
  payload 压进 `upper` 后，64 MiB 的文件系统达到 `used 63/64 MiB`，overlayfs 无法创建
  它的 `work/` 目录。

## 文件系统与子卷

| 分区 | `mkfs` 参数 | 理由 |
|---|---|---|
| p1 | `mkfs.vfat -F 32 -n ESP` | FAT32 标签字段宽 11 个字符；`ESP` 放得下且说明了分区的用途 |
| p2 / p3 | `mkfs.btrfs -m dup -d single -L slot-a`（p3 用 `-L slot-b`） | 元数据只有 4–8 MiB；副本能在一个槽位内部恢复静默损坏 |
| p4 | `mkfs.btrfs -m single -d single -L data` | 容器层会让元数据膨胀；副本不划算 |

| 挂载点 | 选项 |
|---|---|
| `@sys` | `ro,noatime,compress=zstd:6` |
| `@platform` | `ro,noatime` |
| `@overlay-<version>` | `rw,noatime,compress=zstd:6,discard=async` |
| `@docker` | `rw,noatime,nodatacow,nodatasum` |
| `@swap` | `rw,noatime,nodatacow,nodatasum` |
| `@data` | `rw,noatime` |

`compress=` 由文件系统的首次挂载决定，所以 p4 在只读槽位层之前挂载。一个 btrfs 只有一个
压缩级别：p4 挂载 `zstd:6`，其上的每个子卷继承该级别，因此 `@data` 不再单独声明级别。
`@docker` 与 `@swap` 是 `nodatacow`，无论怎样都不压缩。

子卷：

- p2 / p3：`@sys`、`@platform`
- p4：`@overlay-<version>`（内含普通目录 `upper/` 与 `work/`）、`@docker`、`@swap`、`@data`

所有子卷都是顶层子卷。不存在二级或嵌套子卷。`@docker` 与 `@swap` 必须保持独立：快照不
递归进嵌套子卷，而活动的 swapfile 会阻止快照。

镜像断言：从镜像读回的 GPT PARTNAME 与文件系统 LABEL 与本页表格一致；p1 带有
`boot/grub/ab-slot.cfg`，其中恰有一行 `set default=` 和一行 `set fallback=`，且没有
`load_env`/`save_env` 调用；p1 带有 `ab/device.json`，含 GPT 磁盘 GUID 与四个互不相同、
与分区表一致的 PARTUUID；p2/p3 使用率低于 50%；`btrfs subvolume list` 的每一项共享同一
顶层；`mkfs` 参数与本页完全一致。

## p4 首启扩容

p4 出厂 128 MiB，磁盘尾部保持未分配，因此同一镜像适配任何容量。扩容需要**两次启动**：

1. **写分区表的那次启动**判断 p4 是否短于最后可用 LBA，用 `sfdisk --no-reread` 重写 GPT，
   记录 `result=table-written`，然后重启。它从不调整文件系统大小；
2. **它之后的那次启动**发现分区表已到磁盘末尾，只剩 `btrfs filesystem resize max` 一步，
   记录 `result=done`；
3. **之后每次启动**记录 `result=already-full`，这是稳态。

**因此首次启动会自行重启一次，GRUB 会出现两次。** 这是设计在正常工作：第一次启动只能把
分区表写完，第二次才把文件系统扩上去，此后每次都是普通启动。

原来这一步是在写完分区表后立刻执行 `blockdev --rereadpt`（或 `partx -u`），而那块盘正是
本次启动仍在使用的盘；一台真机在首次刷写时就 panic 在这个窗口里。现在启动路径里没有任何
东西要求内核重读分区表：**重启就是重读**，因为下一次启动的内核在设备探测阶段解析 GPT，
此时没有任何挂载。同一个窗口也是这次重启必须受控的原因（归还根子卷并刷写后执行
`reboot -f`）：panic 不会留下任何证据，而重启会留下完成阶段的记录。

initramfs 这一半，按发生顺序：

1. `sfdisk -d` 导出分区表，导出结果留作改动前副本。
2. 判断把 p4 末尾与最后可用 LBA（`last-lba`）比较。相等即 `already-full`，不写任何东西；
   短于则新大小为 `last usable LBA - p4 start + 1`，向下取整到文件系统扇区大小
   （4096 字节，8 个扇区）的整数倍。取整后没有增益则状态为 `already-full`。
3. 动分区表之前，按旧几何挂载 p4 根子卷，写入 `.ab/partitions.before` 与
   `result=table-write-pending`，随即归还挂载。若归还失败，则分区表根本不写，记录为
   `fail:p4-still-mounted`。
4. 只改副本中 p4 那一行的 `size=` 字段；`sfdisk --no-reread` 写回该副本，备份 GPT 在同一次
   写入中搬到新的磁盘末尾。其余每一行，包括表 UUID 与另外三个分区，都原样写回。
5. 读回分区表比对，`sfdisk --verify` 校验主备两份 GPT。写没落地是
   `fail:table-write-not-verified`；校验不过关是 `fail:table-verify`；两者都不重启。
   没有 `--verify` 的 `sfdisk` 记为 `verify=unsupported`，扩容继续。
6. 再次挂载根子卷，记录 `result=table-written`（先把缓冲的 `.ab/grow.log` 追加进去），
   归还挂载、刷写，然后重启。
7. 下一次启动在 p4 的干净挂载上执行 resize（无 `compress=`、无 `discard=`、无 `subvol=`），
   记录 `result=done`。

结果是一行写在 `<p4 根子卷>/.ab/grow`：

```
result=<token> last_lba=<n>
```

| 状态 | 含义 |
|---|---|
| `table-write-pending` | 分区表写入进行中；死在这个窗口里的启动会留下它 |
| `table-written` | 分区表已写入并校验，下一步是重启 |
| `done` | 本次启动已把文件系统扩到新几何 |
| `already-full` | 上一次启动已在该磁盘末尾记录过 `done`/`already-full`；本次什么都没写 |
| `missing-sfdisk` | 这个 initramfs 里没有 `sfdisk`；什么都没写 |
| `fail:<token>` | 某一步失败：`partition-table-read`、`partition-table-write`、`p4-still-mounted`、`table-write-not-verified`、`table-verify`、`table-write-lost`、`resize-mount`、`btrfs-resize` |

单阶段固件写下的记录仍能正确读取：`done` 与 `already-full` 含义不变，已退役的 `fail:`
token 读作"未被证实"。已经扩过容的机器在首次启动这套固件时报告 `already-full`。

`ab-boot` 在运行时收尾：读取 `<p4>/.ab/grow`，在 initramfs 没能完成时重试
`btrfs filesystem resize max /mnt/p4`（p4 恰好挂载一次，btrfs-progs 来自平台层），并在 p1
环形日志里记录 `stage=resize result=<ok|fail:<token>> source=ab-boot`。initramfs 扩容失败
的机器在同一次启动里仍能到达磁盘末尾。

死在半路的启动留下的证据：`ab-boot` 把本次启动的环形日志写入 `ab/log/boot-0.log`，并在
下次启动的第一件事把它轮转为 `boot-1.log`。写分区表的那次启动到不了 `ab-boot`，所以它的
证据在 `.ab/grow`、只追加的 `.ab/grow.log`，以及随后一次上电后的 `boot-1.log` 里；事后
分析读 `ab-slot log --prev`，`boot-0.log` 只用于正在运行的这次启动。改动前的分区表保存在
`.ab/partitions.before`，因为只活在 initramfs 里的副本会随它一起消失。记录放在 p4 根子卷
上而不是某一代可写层里，因此比 `@overlay-<version>` 活得久。

扩容只放大 p4，且幂等。记录唯一决定的是循环保护：如果存在一条 `table-written` 记录，其
磁盘末尾正好是本次启动想写的末尾，而盘上的分区表仍更短，说明写入丢在了文件系统之下；
那次启动记录 `fail:table-write-lost`，而不是再写一次再重启一次。

## 启动链与分层根

1. GRUB 从 p1 读取槽位状态与 `ab-slot.cfg`，选择内核与 initrd。
2. initramfs 判定四个分区在哪块盘上，定位 p1 到 p4，并决定 p4 是否需要扩容。需要则本次
   启动重写分区表、记录，并重启。
3. initramfs 在 p4 的干净挂载上调整文件系统大小，然后挂载 p4 可写层、只读槽位层与 p4
   用户数据子卷。
4. overlayfs 组装根。
5. `switch_root` 进入系统；p1 挂载在 `/boot`。

CI 客户机断言不属于这条链。`/s3-post.sh` 复检组装好的根并打印固定的 `S3-RESULT` 行；只有
构建设置 `AB_CI_HOOKS=1` 时它才会被注入，所以刷到真机上的系统绝不会把 CI 记账当成 PID 1
运行。`scripts/ci/image-verify.sh` 读回两个 initrd 的成员表，并与 `ab/image.json` 记录的
kind 比对。

### 设备身份

启动路径上任何东西都不能假定 `/dev/vda`：这个名字只在 virtio 上存在，而目标板子呈现
`/dev/sda`、`/dev/nvme0n1` 或 `/dev/mmcblk0`。"哪块盘是我们的"只有一个实现：
`platform/lib/disk-identity.sh`，在启动 initramfs 与平台层里以同样的字节发布。

解析顺序，先答先得，且只在有证据时使用某一级：

| 级别 | 证据 | 说明 |
|---|---|---|
| 1 | 内核命令行上的 `ab.disk=`，其次 `wf.dev=` | 测试与 QEMU；仅当该盘带有 `ab-esp` 时接受 |
| 2 | ESP 上 `ab/device.json` 里的 PARTUUID | 构建时写入；`dd` 到另一块盘后仍有效 |
| 3 | PARTNAME | `ab-*` 这类 GPT 名字，经 `/sys/class/block/*/uevent` 扫描 |
| 4 | 挂载反查 | 运行系统中的 `/boot`、`/mnt/p4`、`/data`；以及 initramfs 已挂载的 ESP |
| 5 | 唯一候选 | 唯一一块其分区带有四个文件系统 LABEL 的不可移动磁盘 |

父盘总是从 sysfs 推导：`/sys/class/block/<part>/partition` 说明该节点是分区，上一层目录的
`DEVNAME` 是磁盘；没有代码从名字里去掉一个 `p` 或补一位数字。只有 sysfs 报告
`DEVTYPE=disk` 且 `removable=0` 的盘才算数。四个分区必须解析到同一块盘：分散在两块盘上是
`partitions-split`，出现两份是 `ambiguous-disk`，两者都不动分区表并让启动继续。结果记录为
`stage=device disk=<dev> method=<cmdline|partuuid|partname|mount|unique>`；识别不出启动盘的
那次启动会报告原因，并在不扩容、不挂载 p4 的情况下继续，而不是关机。

### 层与挂载组装

| 层 | 子卷 | 模式 | 内容 | 由谁写入 |
|---|---|---|---|---|
| 上游系统 | `@sys` | ro | 上游 rootfs，逐字节一致 | 仅升级 |
| 平台 | `@platform` | ro | `ab-slot`、init.d 钩子、恢复工具 | 仅升级 |
| 用户状态 | `@overlay-<version>` | rw | 配置、已安装软件包、用户文件 | 运行时 |

`@platform` 随槽位一起版本化：升级时写入，随槽位回滚。

```
/ = overlay(
      lowerdir=/mnt/@platform:/mnt/@sys,
      upperdir=/mnt/p4/@overlay-25.12.2/upper,
      workdir=/mnt/p4/@overlay-25.12.2/work,
      index=off,metacopy=off,redirect_dir=off )
```

- `lowerdir` 顺序固定为 `@platform:@sys`；平台层优先
- `index=off` 避免使用中的排他锁与回滚后的陈旧索引项
- 从不使用 `volatile` 选项

挂载顺序：

1. 以 `rw,compress=zstd:6,discard=async` 从 p4 挂载 `@overlay-<version>`
2. 在该挂载点上执行 `btrfs filesystem resize max`
3. 以 `ro` 挂载 `@platform`
4. 以 `ro` 挂载 `@sys`
5. 在 `/newroot` 组装 overlay
6. 在 `/newroot` 下挂载 `@data`、`@docker`、`@swap`
7. 断言 p4 挂载在 `/proc/mounts` 中的条目包含 `compress=`

p4 先挂载，因为 `compress=` 只由文件系统的首次挂载生效；先挂只读层会让该参数不进入内核。

三个用户数据子卷由 initramfs 自己、通过组装好的根挂载，因此在第一个进程启动前就已就位：

| 子卷 | 挂载点 | 选项 | 原因 |
|---|---|---|---|
| `@data` | `/data` | `rw,noatime` | 用户数据；压缩跟随文件系统 |
| `@docker` | `/opt/docker` | `rw,noatime,nodatacow,nodatasum` | 与上游 dockerd 软件包一致，`option data_root '/opt/docker/'` |
| `@swap` | `/swap` | `rw,noatime,nodatacow,nodatasum` | swapfile 不能 COW、不能压缩 |

这里挂载失败会报告 `p4-partial`，启动继续；`ab-slot status` 在 `p4=` 旁显示三个标记。

`@platform` 镜像最终文件系统路径：`/usr/sbin/ab-slot`、`/usr/sbin/ab-upgrade`、
`/etc/init.d/ab-boot`、`/etc/init.d/ab-commit`、`/lib/ab-slot-cfg.sh`、
`/lib/ab-partitions.sh`、`/usr/sbin/btrfs` 及其运行时库闭包、`/etc/uci-defaults/`。
因为 overlayfs 会合并目录，procd 从合并视图读取 `/etc/init.d/*`，钩子正常运行而 `@sys`
保持不变。

## 槽位状态与启动提示

p1 上的 `ab/state.json` 是事实，原子写入（临时文件、`sync`、rename）：

```json
{
  "generation": 2,
  "committed": "b",
  "pending": null,
  "slots": {
    "a": { "rootfs": "25.12.3", "upper": "@overlay-25.12.3" },
    "b": { "rootfs": "25.12.2", "upper": "@overlay-25.12.2" }
  }
}
```

GRUB 读不了它，所以引导器只拿到一个派生值，写在单独的文件里：

| 产物 | 由谁写 | 由谁读 | 作用 |
|---|---|---|---|
| `ab/state.json` | `ab-slot`（临时文件、`sync`、rename） | initramfs、`ab-boot`、`ab-commit`、`ab-upgrade`、`ab-slot` | 事实：`committed`、`pending`、各层 |
| `boot/grub/ab-slot.cfg` | `ab-slot` 的 `pending`/`commit`/`abandon`/`rollback`、每次启动的 `ab-boot`、以及启动失败路径上的 initramfs | GRUB，通过 `source` | 提示：下次启动运行哪个条目，失败时回退到哪里 |
| `boot/grub/grub.cfg` | 镜像构建一次；升级时来自 payload 的 `boot.tar` | GRUB | 菜单与构建时默认值；任何启动、提交、回滚都不重写它，而升级会整体替换文件并保留旧文件为 `grub.cfg.prev` |
| `ab/candidate` | 切换根之前的启动 initramfs（`<slot> <start-ts> <attempt>`），以及仅在缺失时由 `ab-boot` 写入 | 下次启动的 initramfs、`ab-boot` | 候选标记：仍然存在意味着上次候选启动没走到 `ab-commit` |
| `ab/interrupted` | 发现遗留标记时的启动 initramfs | `ab-boot`，每次启动一次 | 关于被中断候选启动的一行，以 `stage=interrupted` 发布后删除 |

`boot/grub/ab-slot.cfg` 恰好包含两条 GRUB 命令，顺序如下：

```
set fallback=<已提交槽位>
set default=<待定槽位，没有待定槽位时为已提交槽位>
```

每个写入方都通过同一实现（`platform/lib/ab-slot-cfg.sh`）从状态文件推导这两个值，因此
构建、状态命令、启动钩子与启动失败路径不可能互相矛盾。这里没有环境块：ESP 上的 GRUB 是
内建模块的独立 EFI 二进制，没有 `env` 模块。`source` 读取的两行文件在该二进制上可用，而
`scripts/ci/grub-render.sh --verify-esp` 会在允许镜像启动前断言引导器确实带有 `source`、
`test` 与 `serial`。

菜单先定义三个条目、把已提交槽位设为构建时默认值与 fallback，然后才 source 提示文件。
GRUB 遇到第一个错误就停止读取脚本，因此提示文件缺失、被截断或格式错误都不会让机器失去
菜单。条目序号是契约的一部分：槽位 `a` 是条目 0，槽位 `b` 是条目 1。

### 两次写入之间断电

状态文件与提示文件先后写入，各自原子。断电落在间隙里会留下已推进的状态与过时的提示，机器
启动提示所指的槽位。

- `ab-boot` 在每次启动、任何读取之前从状态文件重写提示，因此过时提示只损失一次启动，绝不
  会启动错槽位。
- 提示文件先写 fallback 行：在第一行之后被截断的写入只留下 `set fallback=<committed>`，
  而这正是菜单原有的值。任何截断都不会让 fallback 指向正在尝试的槽位。

### 新槽位不工作时

1. 待定槽位的内核起不来：GRUB 转到 `fallback` 条目，即已提交槽位；
2. 内核起来了但健康检查失败：`ab-commit` 放弃待定槽位，清除 `pending`，把提示指回已提交
   槽位并重启进入它；
3. 内核起来了但启动 initramfs 在用户空间之前失败：失败路径执行同样的 fail-safe 放弃
   （`action=fail-safe-abandon`），然后才关机；
4. 内核起来了、启动在 `ab-commit` 决策前结束（断电、卡死）：下次启动发现候选标记，累计
   尝试次数，记录 `stage=interrupted … result=retry` 并重试。`AB_BOOT_RETRY_MAX`（默认 1）
   限定重试次数，超过上限的那次启动清除 `pending` 并记录
   `stage=interrupted … result=abandon reason=attempt-limit`。

`ab-slot rollback` 是手动路径：提交另一个槽位并随之移动提示。`ab-slot status` 把提示报告为
`next=<a|b|unknown>`，`ab-slot next` 单独打印它。

## 升级事务

可写层以它所属的上游版本命名：`@overlay-<version>`，例如 `@overlay-25.12.2`。每次升级都
新建一层，任何子卷从不改名。同一上游版本被重建时加序号后缀 `@overlay-25.12.2-r2`，因为
平台层可以在 base 不动的情况下重建。名字是给人看的；顺序来自 `ab/state.json` 里只增不减
的整数 `generation`，回收按该数字排序。推论：即使系统从未重启过也能创建新层；回滚只移动
指针；稳态恰好需要两层，每个槽位一层。

| 事件 | p4 | p1 状态 |
|---|---|---|
| 安装 | 创建 `@overlay-25.12.2`、`@docker`、`@swap`、`@data` | `a` 与 `b` 都指向它，`committed=a` |
| 把槽位 B 升到 25.12.3 | `snapshot @overlay-25.12.2 -> @overlay-25.12.3`，写 p3 | `pending=b`，更新 `b.upper` |
| B 启动健康 | — | `committed=b`，清除待定，回收 |
| 把槽位 A 升到 25.12.4 | `snapshot @overlay-25.12.3 -> @overlay-25.12.4`，写 p2 | `pending=a`，更新 `a.upper` |
| A 启动健康 | 删除 `@overlay-25.12.2` | `committed=a`，清除待定 |
| 回滚 | — | 把 `committed` 切到另一个槽位 |

快照源始终是活层。先 `sync` 并停止写入方；一致性是崩溃一致，不是应用一致。

## 健康检查

在 `done` 完成后运行，超时 150 秒：

| 探针 | 通过条件 |
|---|---|
| `overlay-writable` | 组装后的根 `/` 可写且至少有 16 MiB 可用（绝对下限而非百分比：同一条规则在 128 MiB 测试镜像和数百 GiB 的磁盘上必须含义相同） |
| `fw4-present` | nft 规则集非空且存在 `inet fw4` 表 |
| `wan-present` | `network.wan` 引用的设备存在 |

提交前三个探针都必须通过。任何失败都会放弃待定槽位并重启进入已提交槽位。可写层就是根本
身，因此没有单独的 `/overlay` 挂载可测量。每个探针都会运行，即使已经有一个失败：日志必须
在一次启动里点名全部三个，否则一个有两个故障的槽位需要两次启动才能解释清楚。

`fw4-present` 不找守护进程：在 ImmortalWrt 25.12 里 `fw4` 是一次性渲染器，加载规则集后
退出，可观察状态就是规则集本身。`wan-present` 需要一个网络配置来点名设备；种子失败只会
记录 `stage=net-seed result=fail` 并让启动继续。已存在的配置不会被改动，测试也正是用这种
方式注入自己的配置。

任何探针运行之前，先读 `/proc/cmdline`、`/proc/mounts` 与 `/sys/class/net`。一个没有
`/proc` 就起来的升级槽位会因同一个原因让三个探针都失败，所以该原因单独占一行
（`stage=preflight … reason=proc-cmdline-unreadable`），而不是三次匿名失败。

## 回收

引用集是 `slots.a.upper` ∪ `slots.b.upper` 加上待定槽位的层。集合之外的任何 `@overlay-*`
都会被删除，按 `generation` 从旧到新。

四条安全规则：

1. 从不删除当前已挂载的层（检查 `/proc/mounts`）
2. 从不删除待定槽位引用的层
3. 先执行 `btrfs subvolume delete -C` 再执行 `btrfs subvolume sync`；只删除不会立即释放空间
4. 磁盘紧张时从不做完整 balance；balance 本身也需要可用空间

触发时机：成功提交后、每次启动早期、升级失败后，以及按需通过 `ab-slot gc`。

| 可用空间 | 动作 |
|---|---|
| 高于 15% | 正常 |
| 低于 15% | 告警并自动回收 |
| 低于 5% | `platform_check_image` 返回 74，升级被拒绝 |

不使用 qgroup 配额；独占空间按需用 `btrfs filesystem du -s` 测量。

## 日志

目录 `/boot/ab/log/`，总量预算约 350 KiB。

| 文件 | 内容 | 轮转 |
|---|---|---|
| `boot-0.log` | 当前启动 | 每次启动轮转 |
| `boot-1.log` | 上一次启动 | — |
| `boot-2.log` | 再上一次启动 | 超出时删除 |
| `upgrade.log` | 升级自身的输出（若该次运行被保存进去）；`ab-upgrade` 自己不往里写 | 下一次保存的升级会覆盖它 |
| `conflicts.log` | 最近一次冲突报告 | 被下一次升级覆盖 |

- 每个文件 32 KiB；溢出以 `TRUNCATED=1` 标记截断
- 启动钩子每次启动最多 8 次写入，每次都是整文件写：临时文件、`sync`、rename；健康检查随后
  追加自己的探针行
- 状态锁是 ESP 上带 `<boot_id> <pid> <started_at>` 的目录；启动或进程已消失的锁会被接管
  （记录为 `stage=lock action=stale-lock-taken`），因此断电不会让机器无法提交
- 写入点：`initramfs-enter`、`lower-mounted`、`overlay-mounted`、`switch-root`、`slot-cfg`、
  `grow`、`resize`、`healthcheck-done`、`commit` 或 `abandon`、`done`

记录字段固定为 `key=value`：

```
stage=<stage> slot=<a|b> upper=<layer> rootfs=<version> result=<ok|fail>
probe=<overlay-writable|fw4-present|wan-present> result=<pass|fail> [reason=<token>]
stage=preflight slot=<a|b> result=fail reason=<proc-cmdline-unreadable|proc-mounts-unreadable|sysfs-missing>
reason=<lower-mount-failed|overlay-failed|healthcheck-failed|slot-cfg-not-written|btrfs-resize>
action=<commit|reboot-to-committed|degraded-boot>
next=<a|b>
```

命令：`ab-slot status`、`ab-slot log [--prev|--upgrade]`、`ab-slot conflicts`、
`ab-slot gc [--dry-run]`、`ab-slot rollback`、`ab-slot next [--write]`。

## 冲突与处置

升级替换整个 `@sys` 树，而可写层可能含有用户改过的文件。重叠部分按三方比较：

| 符号 | 含义 |
|---|---|
| `A` | 旧槽位 `@sys` 里的文件（基线） |
| `B` | 新槽位 `@sys` 里的文件（新默认） |
| `U` | 可写层里同一路径（用户版本） |

```
UpstreamChanged = { f : A[f] != B[f] }
UserChanged     = { f : U exists and U[f] != A[f] }
Conflicts       = UpstreamChanged ∩ UserChanged
```

- 比较使用内容哈希，绝不用 mtime 或大小
- 基线来自真实的旧 `@sys` 内容，而不是版本号
- 必须识别 whiteout 条目（`0:0` 字符设备）与目录 `opaque` 标记，否则"用户删除了这个文件"
  会从报告里消失

| 情况 | 动作 |
|---|---|
| `U` 不存在、`B` 变了 | 取 `B` |
| `U` 存在、`B` 未变 | 保留 `U` |
| `U` 存在、`B` 也变了 | 保留 `U` 并记录冲突 |
| `U` 存在、`B` 被删 | 标为高风险并要求人工复核 |

冲突从不阻塞升级，也从不阻塞启动。`/etc/config/*` 下的文件绝不逐行合并：uci 有自己的语法，
文本合并会产生无法加载的配置。上游新默认值通过幂等的 `/etc/uci-defaults/` 脚本引入，只填
缺失项并在运行后自删，因此文件级冲突检测只覆盖非 uci 的用户文件。

## payload 契约

| 成员 | 来源 | 实测大小 |
|---|---|---|
| `rootfs.tar.gz` | 官方镜像站 | 10 587 455 B（10.1 MiB） |
| `kernel.bin` | 官方镜像站 | 7 709 696 B（7.35 MiB） |
| `initramfs.cpio.gz` | 本项目 | 3 056 055 B（2.9 MiB） |
| `platform.tar` | 本项目 | 1 484 800 B（1.42 MiB） |
| `boot.tar` | 本项目 | 655 360 B（640 KiB） |
| `manifest.json` | 本项目 | 1 396 B（1.4 KiB） |

六个成员合计 23 494 762 B；承载它们的 payload tar 是 23 500 800 B（22.41 MiB），差值来自
tar 的块填充。因此一个升级 payload 略高于 20 MiB，整盘镜像只用于首次安装。这些大小是实测
而非估算：它们是已发布 `v0.0.8` payload 的成员，`tar -tvf n5105-ab-<upstream>-upgrade.tar`
在你自己的副本上会打印同一份清单。大小随版本变化，形状不变。

`manifest.json` 记录每个成员的大小与 sha256，以及 `format`、`rootfs` 版本、`platform`
版本与 `kernel` 软件包 id。

### 引导器成员

`boot.tar` 让升级把自己的引导器一起带过去。它只含两个文件：

| `boot.tar` 内的路径 | 是什么 |
|---|---|
| `EFI/BOOT/BOOTX64.EFI` | 上游独立的 GRUB EFI 二进制，与 ESP 得到的逐字节一致 |
| `boot/grub/grub.cfg` | 本项目的槽位菜单，由 `scripts/ci/grub-render.sh` 从 `scripts/ci/grub.cfg.in` 渲染 |

manifest 用一个 `bootloader` 块描述这些字节：`member`、`loader`、`menu`、`loader_bytes`
（ESP 余量规则是 `loader_bytes / 1024 + 4096` KiB 可用）、`loader_sha256` 与
`menu_sha256`（设备在写入前后比对的摘要）、`grub_version`（摘要旁的可读证据，从不作为
决策），以及 `source_image` / `source_sha256`（来源）。没有引导源的构建不产生 `boot.tar`
并写 `"bootloader": null`；这是合法 payload，`ab-upgrade` 会打印
`bootloader absent-in-payload` 而不是静默安装。`CI_REQUIRE_BOOTLOADER=1` 会把缺失的引导源
变成构建失败。

该成员只定义一次，在 `scripts/ci/boot-member.sh` 里，由 `scripts/ci/payload-build.sh` 与
`scripts/ci/assemble.sh` 共用，因此测试 payload 与发布 payload 不可能不一致。

不借助设备核对 payload 身份：

```sh
mkdir -p /tmp/payload
tar -xf n5105-ab-<upstream>-upgrade.tar -C /tmp/payload boot.tar manifest.json
tar -xf /tmp/payload/boot.tar -C /tmp/payload
bash scripts/ci/grub-render.sh --check-loader /tmp/payload/EFI/BOOT/BOOTX64.EFI /tmp/payload/manifest.json
```

### 校验顺序

任何失败都会中止升级：

1. `manifest.json` 可解析且 `format` 匹配
2. 每个成员存在且其 sha256 与 manifest 一致
3. `initramfs.cpio.gz` 内 `btrfs.ko` 的 vermagic 与 `kernel.bin` 一致
4. p4 至少有 5% 可用空间
5. 冲突报告已生成

失败时 `platform_check_image` 返回 74，因此即使 `sysupgrade -F` 也拒绝写入。

### 构建输入与适配器

流水线不编译内核，只消费官方产物：`immortalwrt-<ver>-x86-64-rootfs.tar.gz`、
`immortalwrt-<ver>-x86-64-generic-kernel.bin`，以及
`kmods/<kernel-ver>-<hash>/kmod-fs-btrfs.apk` 及其依赖。预检：kmods 目录名里的 hash 必须
等于 `kernel` 软件包版本里内嵌的 hash。

| 适配器 | 行为 |
|---|---|
| `upstream` | 下载官方 rootfs 与内核（默认） |
| `selfbuild` | 使用本地构建的 rootfs 与内核（保留接缝，未实现） |

切换适配器不改变组装层或 initramfs。

### btrfs 为什么以模块形式到达

25.12.2 的 `config.buildinfo` 里没有 `CONFIG_KERNEL_BTRFS_FS`，默认镜像清单列出 227 个
软件包且不含 btrfs。因此 btrfs 只能由从 initramfs 加载的 `kmod-fs-btrfs` 提供。这是
"消费上游产物"这条路的前提。

## 限制

- 回滚深度为一层：升级会覆盖目标槽位的 rootfs，更早的 rootfs 镜像在磁盘上已不存在。
- 扩容从不缩小 p4。比镜像更小的磁盘会让分区表描述不存在的空间，扩容以
  `fail:p4-beyond-disk` 拒绝。
- 降级启动把 `upperdir` 放在 tmpfs 里：系统能跑但不持久化写入。`ab-slot status` 报告
  `boot=degraded`，`ab-upgrade` 以 `writable-layer-degraded` 拒绝。
- payload 格式未签名。`UPDATE_VERIFY` 为签名模式留了位置，但没有实现；摘要的可信度只等于
  它到达时所经 HTTPS 连接的可信度。

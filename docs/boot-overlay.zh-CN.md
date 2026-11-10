# 引导链与分层根

[English](boot-overlay.md) | **简体中文**

## 概述

运行期根由 overlayfs 合成：活动槽的两个只读层，加上数据分区上的一个可写层。合成之前，initramfs 先确定四个分区在哪块盘上，把 p4 扩到盘尾，再挂载三个用户数据子卷，因此合成根的第一个进程看到的就已经是最终几何与自己的数据目录。

## 引导顺序

1. GRUB 从 p1 读取槽状态与 `ab-slot.cfg`，选择内核与 initrd。
2. initramfs 先解析出承载四个分区的盘，再在其上定位 p1..p4，并在挂载任何文件系统之前把 p4 扩到盘尾。
3. initramfs 先挂载 p4 可写层并扩容文件系统，再挂载槽内只读层与 p4 的三个用户数据子卷。
4. overlayfs 合成根。
5. `switch_root` 进入系统，p1 挂载到 `/boot`。

## 设备身份

引导路径上任何地方都不得假设 `/dev/vda`：这个名字只在 virtio 上存在，而目标板呈现的是 `/dev/sda`、`/dev/nvme0n1` 或 `/dev/mmcblk0`。“这块盘是不是我们的”只有一处实现：`platform/lib/disk-identity.sh`，它同时以相同字节装进 boot initramfs 与平台层。

解析顺序，先命中的一级说了算，且只有拿到证据才会采用：

| 级别 | 依据 | 备注 |
|---|---|---|
| 1 | 内核参数 `ab.disk=`，其次 `wf.dev=` | 测试与 QEMU 用；只有该盘承载 `ab-esp` 才被接受 |
| 2 | ESP 上 `ab/device.json` 里的 PARTUUID | 构建期写入；`dd` 到别的盘也不变 |
| 3 | PARTNAME | 扫 `/sys/class/block/*/uevent` 里的 `ab-*` GPT 名 |
| 4 | 挂载反查 | 运行期看 `/boot`、`/mnt/p4`、`/data`；initramfs 看已挂载的 ESP 分区 |
| 5 | 唯一候选 | 只有一块非 removable 盘的分区带齐四个文件系统 LABEL |

- 父盘一律由 sysfs 推导：`/sys/class/block/<part>/partition` 说明该节点是分区，其上一层目录里的 `DEVNAME` 就是盘。没有任何代码去裁名字里的 `p`，也没有任何代码把数字拼到设备名后面。
- 只有 sysfs 报 `DEVTYPE=disk` 且 `removable=0` 的盘才算数，U 盘与 loop 设备永远不会被写。
- 四个分区必须解析到同一块盘：分处两块盘是 `partitions-split`，整套名字存在两份是 `ambiguous-disk`。两种情况都不动分区表，也都继续启动。
- 结果按 `stage=device disk=<dev> method=<cmdline|partuuid|partname|mount|unique>` 记录，`ab-slot status` 从同一处解析器给出相同的 `disk=` 与 `method=`。
- initramfs 在挂载 ESP 之前就解析，所以第 2 级在那里只有 `ab/device.json` 已可读时才生效；`ab-boot` 在 `/boot` 挂好之后会把整条阶梯再跑一遍。认不出盘的启动只上报原因并跳过扩容与 p4 挂载，不会关机。

## p4 首启扩容

p4 出厂 128 MiB，盘尾保持未分配，因此同一个镜像能装进任意大小的盘。扩容分两处做，第二处才是保证：

- **initramfs，尽力而为**：合成 overlay 之前改写分区表并 resize 一次文件系统。这样首次启动当场就
  可用；这一步失败只记录（`fail:<token>`），绝不阻断启动；
- **运行期 `ab-boot`，权威路径**：它读取 `<p4>/.ab/grow`，在 initramfs 没能扩成时重试
  `btrfs filesystem resize max /mnt/p4`（p4 只挂一次、btrfs-progs 来自平台层），并把
  `stage=resize result=<ok|fail:<token>> source=ab-boot` 写进 p1 环形日志。initramfs 那次失败
  的机器，同一次启动仍能扩到盘尾。

initramfs 这半段的顺序，发生在任何文件系统挂载之前：

1. `sfdisk -d` 导出分区表，导出结果就是改动前的备份。
2. 判定：比较 p4 末尾与最后可用 LBA（`last-lba`）。相等即 `already-full`，不写任何东西；否则新大小为“最后可用 LBA − p4 起始 + 1”，只会比当前大。
   新尺寸先按文件系统 sectorsize（4096 字节，即 8 个扇区）向下取整：btrfs 不会扩到尺寸不是它整数倍的设备上，所以“最后可用 LBA − p4 起始 + 1”只是上界；取整后若不比当前更大，判 `already-full`。
3. 在导出的副本里只改 p4 行的 `size=` 字段，用 `sfdisk --no-reread` 写回；备份 GPT 随这次写入一起迁移到新的盘尾。其余各行（含表 UUID 与另外三个分区）原样写回。
4. `blockdev --rereadpt`（镜像里没有 `blockdev` 时用 `partx -u`）让内核看到新表；挂载前先在 sysfs 校验设备确实变大了。sysfs 的 `size` 以 512 字节为单位，而 `sfdisk` 报的是逻辑扇区，所以每次比较都经 `queue/logical_block_size` 换算：4Kn 盘会被正常扩容，而不是误报 `fail:size-unchanged`。
5. 挂载 p4 之后执行 `btrfs filesystem resize max`，把文件系统扩到已经变大的分区上。该命令在 `already-full` 时也会跑一次（此时是空操作），因此“表已改写、文件系统没来得及扩”的掉电情况会在下一次启动被修好。

结果写在 `<p4 根子卷>/.ab/grow`，固定一行：

```
result=<state> last_lba=<n>
```

| 状态 | 含义 |
|---|---|
| `done` | 分区表与文件系统都扩到了盘尾 |
| `already-full` | p4 已达盘尾，什么都没写 |
| `missing-sfdisk` | 这个 initramfs 里没有 `sfdisk`，什么都没写 |
| `fail:<token>` | 某一步失败：`partition-table-read`、`partition-table-write`、`partition-table-reread`、`size-unchanged`、`size-not-increased`、`btrfs-resize`，以及认不出盘时的 `no-disk` / `ambiguous-disk` / `partitions-split` |

改动前的分区表在 p4 挂载后落到 `<p4 根子卷>/.ab/partitions.before`：只留在 initramfs 里的副本会随它一起消失，那不算留存。

记录写在 p4 根子卷上，而不是某个代际层里，因此它能跨 `@overlay-<version>` 存活并在切换根之后仍可读：`ab-boot` 把该子卷挂到 `/mnt/p4` 并把这一行追加进 p1 引导日志。写入走临时文件加 rename；文件缺失对读取方表示“未记录”，永远不是错误；镜像本身不带这个文件。

扩容只扩不缩，并且幂等，因为判定只依赖盘上的分区表：同一块盘第二次启动读到 `already-full`，不会碰分区表。`sfdisk`、`blockdev` 与 `btrfs` 属于 boot initramfs 的 `boot` 工具集（`scripts/ci/initramfs-tools.lock.json`），因此一定存在、且与整份 release 的字节一致；工具集若丢了它们，构建直接失败。启动时的 `missing-sfdisk` 与 `fail:btrfs-resize` 仍然保留，但语义变成“分区表/设备有问题”的运行时诊断，而不是“构建机恰好没装”。

## 层职责

| 层 | 子卷 | 模式 | 内容 | 写入方 |
|---|---|---|---|---|
| 上游系统 | `@sys` | ro | 上游 rootfs，逐字节一致 | 仅升级 |
| 平台 | `@platform` | ro | `ab-slot`、init.d 钩子、修复工具 | 仅升级 |
| 用户状态 | `@overlay-<version>` | rw | 配置、已安装软件、用户文件 | 运行期 |

`@platform` 与槽版本绑定：升级时写入，回退时随槽退回。

## 挂载合成

```
/ = overlay(
      lowerdir=/mnt/@platform:/mnt/@sys,
      upperdir=/mnt/p4/@overlay-25.12.2/upper,
      workdir=/mnt/p4/@overlay-25.12.2/work,
      index=off,metacopy=off,redirect_dir=off )
```

- `lowerdir` 顺序固定为 `@platform:@sys`，平台层优先
- `index=off` 避免 in-use 排他锁，以及回退后残留的 index 项
- 不使用 `volatile` 选项

## 挂载顺序

1. 以 `rw,compress=zstd:6,discard=async` 挂载 p4 的 `@overlay-<version>`
2. 在该挂载点上执行 `btrfs filesystem resize max`
3. 以 `ro` 挂载 `@platform`
4. 以 `ro` 挂载 `@sys`
5. 在 `/newroot` 合成 overlay
6. 把 `@data`、`@docker`、`@swap` 挂到 `/newroot` 之下
7. 断言 p4 挂载行的 `/proc/mounts` 条目包含 `compress=`

先挂 p4 的原因：`compress=` 只由文件系统的首次挂载生效，若先挂只读层，该参数不会进入内核。

## p4 数据子卷

三个用户数据子卷由 initramfs 自己挂载，时机在 overlay 合成之后、并穿过它完成，因此合成根的第一个进程启动时它们已经在位。挂载点先用 `mkdir -p` 建在 `/newroot` 下，`switch_root` 之后就是 `/data`、`/opt/docker` 与 `/swap`。

| 子卷 | 挂载点 | 选项 | 理由 |
|---|---|---|---|
| `@data` | `/data` | `rw,noatime` | 用户数据；压缩级别跟随文件系统 |
| `@docker` | `/opt/docker` | `rw,noatime,nodatacow,nodatasum` | 对齐上游 dockerd 包的 `option data_root '/opt/docker/'` |
| `@swap` | `/swap` | `rw,noatime,nodatacow,nodatasum` | swapfile 不得 COW、不得压缩 |

`compress=` 是文件系统级选项：一个 btrfs 只能有一个级别，p4 统一用 `zstd:6`。只有 `@overlay` 那次挂载带它，三个子卷挂载一律不再写压缩选项，也不再有哪个层自称一个级别（旧文档里 `@data` 的 `zstd:3` 说法是错的）。`nodatacow` 与 `nodatasum` 只是复述构建期的 `chattr +C`，这样即使选项丢了，也不会悄悄在 swapfile 上开 COW。

`@docker` 挂 `/opt/docker`、`@swap` 挂 `/swap` 都不会让启动失败：挂载失败记为 `p4-partial`，日志行会列出缺了哪些子卷，启动继续；`ab-slot status` 在 `p4=` 旁边给出这三个标记。

## 平台层如何生效

`@platform` 按最终路径组织：

- `/lib/disk-identity.sh`、`/lib/ab-partitions.sh`
- `/usr/sbin/ab-slot`
- `/etc/init.d/ab-boot`、`/etc/init.d/ab-commit`
- `/etc/uci-defaults/`

overlayfs 会合并目录，procd 从合并视图读取 `/etc/init.d/*`，钩子正常执行，而 `@sys` 不受改动。

## 选槽：谁写引导提示

`boot/grub/grub.cfg` 在构建期渲染一次，运行期永不改写：整份菜单写到一半掉电是起不来的机器，而提示写坏最多损失一次启动。

- 真相是 ESP 上的 `ab/state.json`；`committed` 与 `pending` 只经 `ab-slot` 的原子 rename 改变
- 提示文件是 `boot/grub/ab-slot.cfg`，两条 GRUB 命令：**先** `set fallback=<已提交槽>`，**后** `set default=<待试槽，或已提交槽>`
- 它只有两个写入方：`ab-slot` 的四条状态命令（`pending`、`commit`、`abandon`、`rollback`），以及 `ab-boot` 每次启动按 `ab/state.json` 自愈；两者都在同目录写临时文件再 rename，读取方永远看不到半个文件
- GRUB 只读：菜单项先定义，之后才是 `if [ -f /boot/grub/ab-slot.cfg ]; then source /boot/grub/ab-slot.cfg; fi`
- 因为 `fallback` 先写，被截断的文件只会让 `fallback` 停在已提交槽、`default` 停在构建期值：机器启动已提交槽，`fallback` 绝不会指向正在试的槽
- `source` 放在菜单项之后是有意的：GRUB 遇到未知命令或语法错会中止整个配置并掉到命令行，那时机器就起不来了
- 镜像复用的上游 GRUB 是 standalone EFI，没有 `env` 模块，所以环境块这条路不存在；`source` 一个两行文件不需要任何模块
- pending 槽若在 initramfs 内失败，会在关机前被放弃：`wf_fail` 先把 ESP 以读写重挂，调用与 `ab-slot abandon` 同一个写入器（`ab_slot_cfg_write_committed`），之后才打印判据行，因此看到判据行就停机的外部工装不会把这次写入截成半截；没有 pending 时什么都不写

渲染结果必须全部满足，否则构建失败：

- 含已提交槽的 `set default=`，以及一个不同的 `set fallback=`
- 三个菜单项定义在 `source` 行之前
- 只在文件存在时 `source` `ab-slot.cfg`
- 不使用 `&&`、`||`、`${x:-y}`
- 无未替换的模板记号

## 故障与降级启动

| 故障 | 行为 |
|---|---|
| 内核或 initrd 加载失败 | GRUB 内联重试，再 `set fallback` 回到已提交槽 |
| initramfs 阶段失败 | 在 ESP 上放弃 pending 槽，然后重启进入已提交槽 |
| 健康检查失败 | 放弃待提交槽，回到已提交槽 |
| p4 扩容失败 | 在 `.ab/grow` 记录 `fail:<token>`；运行期 `ab-boot` 会再试一次文件系统扩容 |
| 分区表扩了但 initramfs 的 resize 失败 | 启动继续；由 `ab-boot` 把文件系统扩上去（`stage=resize result=ok source=ab-boot`） |
| initramfs 缺 `sfdisk` | 记录 `missing-sfdisk`，启动不变 |
| 认不出引导盘 | 记录 `fail:no-disk` / `fail:ambiguous-disk` / `fail:partitions-split`，绝不写分区表，继续启动 |
| 用户数据子卷挂载失败 | 记录 `p4-partial` 并继续，挂载点留空 |
| p4 挂载失败 | 重试，再以 `recovery` 只读挂载，最后用 tmpfs 上层降级启动 |

降级启动时 `upperdir` 位于 tmpfs：系统可用但不持久。
`ab-slot status` 仍可使用，因为 `@platform` 在 p2/p3 上，不在 p4。

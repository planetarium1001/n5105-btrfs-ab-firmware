# 引导链与分层根

[English](boot-overlay.md) | **简体中文**

## 概述

运行期根由 overlayfs 合成：活动槽的两个只读层，加上数据分区上的一个可写层。合成之前，initramfs 先确定四个分区在哪块盘上，把 p4 扩到盘尾——分**两次**启动完成，见 [p4 首启扩容](#p4-首启扩容)——再挂载三个用户数据子卷，因此合成根的第一个进程看到的就已经是最终几何与自己的数据目录。

## 引导顺序

1. GRUB 从 p1 读取槽状态与 `ab-slot.cfg`，选择内核与 initrd。
2. initramfs 先解析出承载四个分区的盘，再在其上定位 p1..p4，并判定 p4 是否需要扩容。需要的话，这一次启动只改写分区表、记录结果，然后重启；下一次启动看到的分区表已经在盘尾。
3. initramfs 先在 p4 的干净挂载点上扩容文件系统，再挂载 p4 可写层、槽内只读层与 p4 的三个用户数据子卷。
4. overlayfs 合成根。
5. `switch_root` 进入系统，p1 挂载到 `/boot`。

CI 自检件不属于这条链。`/s3-post.sh` 在合成根里复查环境、把探针文件写进可写层、并打印固定的 `S3-RESULT` 行；它是测试件，因此只有当构建设了 `AB_CI_HOOKS=1` 时才会被注入 initramfs。未设该标志时归档里没有这个成员，boot init 交给 `/sbin/init` 而不是交给探针：刷好的机器不能把 CI 记账当 PID 1 跑——探针写会落进用户可写层，失败分支还会关机。S3 阶段的断言照旧：它为两次内核启动用该标志另建一个 initramfs，而它发布的镜像由不带该成员的归档装配。`scripts/ci/image-verify.sh` 会回读两个 initrd 的成员表（`cpio -t`，不得出现 `s3-` 条目）并与 `ab/image.json` 记录的 kind 比对，因此这条规则由构建把关，而不是靠评审。

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

p4 出厂 128 MiB，盘尾保持未分配，因此同一个镜像能装进任意大小的盘。扩它需要**两次启动**，这是设计选择，不是实现凑出来的：

1. **写表的那一次启动**：判定 p4 是否短于最后可用 LBA，用 `sfdisk --no-reread` 改写 GPT，
   记下 `result=table-written`，然后重启。这一次启动**不**扩文件系统；
2. **它之后的那一次启动**：分区表已经在盘尾，剩下的唯一一步就是 `btrfs filesystem resize max`，
   记下 `result=done`；
3. **再往后的每次启动**：记下 `result=already-full`，这就是稳态。

**因此首启会自己多重启一次，GRUB 会出现两次。** 这是设计在正常工作，不是故障：第一次启动只能把分区表
做完，第二次才把文件系统做完；之后每次启动都是普通启动。

为什么要两次启动：原来这一步紧接着写表就去调 `blockdev --rereadpt`（或 `partx -u`），而用的是
这次启动自己还在使用的那块盘——真机首次刷机就是在这个窗口里 panic 的，盘上一条证据都没留下。
现在引导路径里**没有任何**让内核重读分区表的调用：**重启就是重读**，因为下一次启动的内核在探测
设备时会自己解析 GPT，此时没有任何东西被挂载。同一个窗口也是为什么重启必须**受控**（先归还根子卷、
刷写完成，再 `reboot -f`）：那里 panic 会一条证据都不留，而重启会留下"哪一阶段做完了"的记录。

initramfs 这半段，按发生顺序：

1. `sfdisk -d` 导出分区表，导出结果就是改动前的备份。
2. 判定：比较 p4 末尾与最后可用 LBA（`last-lba`）。相等即 `already-full`，不写任何东西；否则新大小为“最后可用 LBA − p4 起始 + 1”，只会比当前大。
   新尺寸先按文件系统 sectorsize（4096 字节，即 8 个扇区）向下取整：btrfs 不会扩到尺寸不是它整数倍的设备上，所以“最后可用 LBA − p4 起始 + 1”只是上界；取整后若不比当前更大，判 `already-full`。
3. **在碰分区表之前**，先按旧几何挂载 p4 根子卷，把两样东西写在扩容记录旁边：`.ab/partitions.before`
   与 `result=table-write-pending`，然后立刻归还挂载。这是"写前面包屑"：写表过程中死掉的启动，
   仍会在盘上留下"有一次写在进行中"以及改动前的几何。如果这次挂载归还不了，就干脆不写表，
   记录为 `fail:p4-still-mounted`：在文件系统仍挂载时写分区表正是那次事故的另一半。
4. 在导出的副本里只改 p4 行的 `size=` 字段，用 `sfdisk --no-reread` 写回；备份 GPT 随这次写入一起迁移到新的盘尾。其余各行（含表 UUID 与另外三个分区）原样写回。
5. 回读分区表比对，并用 `sfdisk --verify` 校验主/备 GPT：没落盘的写判 `fail:table-write-not-verified`，
   校验不过判 `fail:table-verify`，两者都不重启。`sfdisk` 没有 `--verify` 选项时记 `verify=unsupported`
   并继续扩容。
6. 再次挂载根子卷，记下 `result=table-written`（先把缓冲的 `grow.log` 追加进 `.ab/grow.log`），
   归还挂载，刷写完成，然后重启。
7. 下一次启动在 p4 的干净挂载点上扩容（不带 `compress=`、不带 `discard=`、不带 `subvol=`），
   记下 `result=done`。

结果写在 `<p4 根子卷>/.ab/grow`，固定一行：

```
result=<token> last_lba=<n>
```

| 状态 | 含义 |
|---|---|
| `table-write-pending` | 有一次写表在进行中；写表窗口里死掉的启动会留下它 |
| `table-written` | 分区表已写入并已校验，下一步是重启 |
| `done` | 这次启动把文件系统扩到了新几何上 |
| `already-full` | 上一次启动已在这个盘尾记过 `done`/`already-full`，本次什么都没写 |
| `missing-sfdisk` | 这个 initramfs 里没有 `sfdisk`，什么都没写 |
| `fail:<token>` | 某一步失败：`partition-table-read`、`partition-table-write`、`p4-still-mounted`、`table-write-not-verified`、`table-verify`、`table-write-lost`、`resize-mount`、`btrfs-resize` |

单阶段固件写下的记录仍然读得懂：`done` 与 `already-full` 语义不变，已退役的
`partition-table-reread` 之类 `fail:` token 读作“未被证明”。因此一台早已扩完的机器换上这套固件后，
第一次启动就报 `already-full`。

**运行期 `ab-boot`，权威路径**：它读取 `<p4>/.ab/grow`，在 initramfs 没能扩成时重试
`btrfs filesystem resize max /mnt/p4`（p4 只挂一次、btrfs-progs 来自平台层），并把
`stage=resize result=<ok|fail:<token>> source=ab-boot` 写进 p1 环形日志。initramfs 那次失败
的机器，同一次启动仍能扩到盘尾。

一次"死掉"的启动，它的证据落在哪：`ab-boot` 把本次启动的环形日志写到
`ab/log/boot-0.log`，而下一次启动的第一件事就是把它轮转成 `boot-1.log`。所以一次
**没能走到 `ab-boot`** 的启动——写表的那一次正是如此，而且是设计如此——它的证据在 `.ab/grow`、
只追加的 `.ab/grow.log`，以及下一次上电之后的 `ab/log/boot-1.log` 里；事后取证读
`ab-slot log --prev`（即 `ab/log/boot-1.log`），`boot-0.log` 只代表"正在运行的这一次"。

改动前的分区表在写表**之前**就落到 `<p4 根子卷>/.ab/partitions.before`：只留在 initramfs 里的副本会随它一起消失，那不算留存。

记录写在 p4 根子卷上，而不是某个代际层里，因此它能跨 `@overlay-<version>` 存活并在切换根之后仍可读：`ab-boot` 把该子卷挂到 `/mnt/p4` 并把这一行追加进 p1 引导日志。写入走临时文件加 rename；文件缺失对读取方表示“未记录”，永远不是错误；镜像本身不带这个文件。

扩容只扩不缩，并且幂等，因为判定只依赖盘上的分区表：同一块盘第二次启动读到 `already-full`，不会碰分区表。记录唯一参与决策的地方是防重启循环：如果记录说 `table-written`、盘尾正好是本次要写的那个值，
而盘上的表仍然更短，说明这次写在文件系统之下丢了——这样的启动改记 `fail:table-write-lost`，
不再写也不重启，所以丢一次写不会变成重启循环。`sfdisk`、`blockdev` 与 `btrfs` 属于 boot initramfs 的 `boot` 工具集（`scripts/ci/initramfs-tools.lock.json`），因此一定存在、且与整份 release 的字节一致；工具集若丢了它们，构建直接失败。启动时的 `missing-sfdisk` 与 `fail:btrfs-resize` 仍然保留，但语义变成“分区表/设备有问题”的运行时诊断，而不是“构建机恰好没装”。

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

`boot/grub/grub.cfg` 在构建期渲染一次，之后启动、提交、回滚都不改写它：整份菜单写到一半掉电是起不来的机器，而提示写坏最多损失一次启动。另一个写者是升级，而且它是整文件替换而不是就地编辑：载荷的 `boot.tar` 带着新渲染的菜单，`ab-upgrade` 用 `<file>.new` + rename 换上去，被换掉的菜单留成 `grub.cfg.prev`。上面那个理由仍然成立，因为从来没有谁把半份菜单写进那个决定机器能不能起来的文件。

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

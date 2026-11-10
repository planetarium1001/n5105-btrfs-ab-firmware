# 分区与文件系统

[English](partitions.md) | **简体中文**

## 概述

单盘、GPT、仅 UEFI。布局提供两个独立的系统槽，以及一个承载全部可写状态的共享分区。

## 布局

| 分区 | GPT PARTNAME | 文件系统 LABEL | 大小 | 文件系统 | 内容 |
|---|---|---|---|---|---|
| p1 | `ab-esp` | `ESP` | 128 MiB | vfat | GRUB、启动菜单、`vmlinuz-a/b`、`initrd-a/b`、`ab/` 状态、`ab/log/`、`ab/device.json` |
| p2 | `ab-slot-a` | `slot-a` | 128 MiB | btrfs | `@sys`、`@platform` |
| p3 | `ab-slot-b` | `slot-b` | 128 MiB | btrfs | `@sys`、`@platform` |
| p4 | `ab-data` | `data` | 至盘尾 | btrfs | `@overlay-<版本>`、`@docker`、`@swap`、`@data` |

不使用 p128（EF02），不保留 legacy 引导路径。

## 命名

每个分区带两套名字，二者不可互换：

| 名字集 | 取值 | 谁依赖它 |
|---|---|---|
| GPT PARTNAME | `ab-esp`、`ab-slot-a`、`ab-slot-b`、`ab-data` | 引导代码，把它与 `/sys/class/block/*/uevent` 比对 |
| 文件系统 LABEL | `ESP`、`slot-a`、`slot-b`、`data` | 人，以及镜像阶段里 `blkid` / `lsblk` 的断言 |

PARTNAME 保留 `ab-` 前缀。分区发现在整机上遍历所有块设备，裸名 `data` 或 `esp` 迟早会
匹配到无关的盘并挂错分区。解析这些名字的代码有四处：`initramfs/boot/init`、
`/etc/init.d/ab-boot`、`/etc/init.d/ab-commit` 与 `lib/upgrade/platform.sh`；四处都在
PARTNAME 缺失时按 1/2/3/4 顺序兜底，因此漏改一处不会在启动时报错，而是被兜底掩盖。

LABEL 不带版本。版本已有三个权威位置：`@overlay-<版本>`、`/etc/platform-release` 与
`ab/state.json`。每次发布都重打 LABEL 会多出一次可能被掉电打断的超级块写入，而半写的
LABEL 读回来是另一个分区。

p4 的旧名 `ab-shared` 已退役：该分区承载可写 overlay、`@data`、`@docker` 与 `@swap`，
不只是"共享"。

p1 只放数据，不放可执行脚本：FAT32 没有权限位与符号链接、没有日志，且 ESP 上的脚本不随槽回滚。

## 尺寸依据

实测基线，ImmortalWrt 25.12.2 x86-64：

| 项目 | 取值 |
|---|---|
| `rootfs.tar.gz` | 10.1 MiB |
| 解压后 rootfs | 26.9 MiB，1078 个文件 |
| 4K 块占用 | 31 MiB |
| `zstd:6` 压缩后 | 10.3 MiB |
| `generic-kernel.bin` | 7.35 MiB |

**p1 = 128 MiB**

| 项目 | 估算 |
|---|---|
| `BOOTX64.EFI` 与 GRUB 模块 | 3–6 MiB |
| `vmlinuz-a/b`（各约 7.4 MiB） | 15 MiB |
| `initrd-a/b`（各 2–3 MiB） | 4–6 MiB |
| `ab-slot.cfg`、槽状态、日志 | 小于 1 MiB |
| 峰值合计 | 约 27 MiB |

余量约 4×。构建期断言 p1 内容不超过 64 MiB，超出即失败。

**p2 = p3 = 128 MiB**

- 为解压后 rootfs 的 4.7×，为 `zstd:6` 后的 12×
- 2 的幂对齐，便于核算
- 运行期只读，仅在升级时写入

**p4 = 至盘尾**

镜像内预建 64 MiB。首次启动扩展到盘尾并执行 `btrfs filesystem resize max`。

## 文件系统参数

| 分区 | `mkfs` 参数 | 理由 |
|---|---|---|
| p1 | `mkfs.vfat -F 32 -n ESP` | FAT32 的卷标字段宽 11 个字符，`ESP` 放得下且直接说明分区用途 |
| p2 / p3 | `mkfs.btrfs -m dup -d single -L slot-a`（p3 用 `-L slot-b`） | 元数据 4–8 MiB，复制可恢复槽内静默损坏 |
| p4 | `mkfs.btrfs -m single -d single -L data` | 容器层会撑大元数据，复制不划算 |

## 挂载参数

| 挂载点 | 参数 |
|---|---|
| `@sys` | `ro,noatime,compress=zstd:6` |
| `@platform` | `ro,noatime` |
| `@overlay-<version>` | `rw,noatime,compress=zstd:6,discard=async` |
| `@docker` | `rw,noatime,nodatacow,nodatasum` |
| `@swap` | `rw,noatime,nodatacow,nodatasum` |
| `@data` | `rw,noatime` |

`compress=` 由文件系统的首次挂载决定，因此先挂 p4，再挂只读槽层。一个 btrfs 只有一个
级别：p4 以 `zstd:6` 挂载，其上的子卷全部继承该级别，因此 `@data` 不再单列级别；
`@docker` 与 `@swap` 是 `nodatacow`，无论如何都不压缩。

## 子卷

- p2 / p3：`@sys`、`@platform`
- p4：`@overlay-<版本>`（内含普通目录 `upper/` 与 `work/`）、`@docker`、`@swap`、`@data`

全部为顶级子卷，不存在二级或嵌套子卷。
`@docker` 与 `@swap` 必须独立：快照不递归进入嵌套子卷，且活动 swapfile 会阻止快照。

## 首启扩容

1. `sfdisk` 读取分区表。
2. 整表写回，把 p4 末端移到盘尾。
3. `partx -u` 重新读取。
4. `btrfs filesystem resize max` 扩展 p4。

新的 p4 尺寸按文件系统 sectorsize（4096 字节，即 8 个扇区）**向下取整**：设备尺寸不是它的整数倍时
btrfs 直接返回 `Invalid argument`，而少几个扇区的盘尾没有代价、未对齐则会让整次扩容失败。取整后若不比
当前更大，判 `already-full` 且不写分区表。

结果写入 p1 日志：`done`、`already-full`、`missing-sfdisk` 或 `fail`。

## 断言

- GPT PARTNAME 与文件系统 LABEL 均与布局表一致，且从镜像读回校验
- p1 内的 `boot/grub/ab-slot.cfg` 各有一行 `set default=` 与 `set fallback=`，default 指向
  已提交槽，且不含 `load_env`/`save_env` 调用：本镜像的 GRUB 没有环境块可读可写
- p1 内的 `ab/device.json` 含 GPT 磁盘 GUID、四个互不相同的 PARTUUID（与分区表一致）
  以及文件系统实际持有的 label
- p1 内容峰值不超过 64 MiB
- p2 / p3 使用率不超过 50%
- `btrfs subvolume list` 中所有条目 top level 一致
- `mkfs` 参数与上表逐字一致

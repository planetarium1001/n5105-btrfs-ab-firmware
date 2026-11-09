# 分区与文件系统

[English](partitions.md) | **简体中文**

## 概述

单盘、GPT、仅 UEFI。布局提供两个独立的系统槽，以及一个承载全部可写状态的共享分区。

## 布局

| 分区 | PARTLABEL | 大小 | 文件系统 | 内容 |
|---|---|---|---|---|
| p1 | `ab-esp` | 128 MiB | vfat | GRUB、`grubenv`、`vmlinuz-a/b`、`initrd-a/b`、`ab/` 状态、`ab/log/` |
| p2 | `ab-slot-a` | 128 MiB | btrfs | `@sys`、`@platform` |
| p3 | `ab-slot-b` | 128 MiB | btrfs | `@sys`、`@platform` |
| p4 | `ab-shared` | 至盘尾 | btrfs | `@overlay-<版本>`、`@docker`、`@swap`、`@data` |

不使用 p128（EF02），不保留 legacy 引导路径。

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
| `grubenv`、槽状态、日志 | 小于 1 MiB |
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
| p2 / p3 | `mkfs.btrfs -m dup -d single` | 元数据 4–8 MiB，复制可恢复槽内静默损坏 |
| p4 | `mkfs.btrfs -m single -d single` | 容器层会撑大元数据，复制不划算 |

## 挂载参数

| 挂载点 | 参数 |
|---|---|
| `@sys` | `ro,noatime,compress=zstd:6` |
| `@platform` | `ro,noatime` |
| `@overlay-<version>` | `rw,noatime,compress=zstd:6,discard=async` |
| `@docker` | `rw,noatime,nodatacow,nodatasum` |
| `@swap` | `rw,noatime,nodatacow,nodatasum` |
| `@data` | `rw,noatime,compress=zstd:3` |

`compress=` 由文件系统的首次挂载决定，因此先挂 p4，再挂只读槽层。

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

结果写入 p1 日志：`done`、`already-full`、`missing-sfdisk` 或 `fail`。

## 断言

- p1 内容峰值不超过 64 MiB
- p2 / p3 使用率不超过 50%
- `btrfs subvolume list` 中所有条目 top level 一致
- `mkfs` 参数与上表逐字一致

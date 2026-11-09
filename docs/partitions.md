# 分区与文件系统

## 布局

EFI-only，GPT，单盘。

| 分区 | PARTLABEL | 大小 | 文件系统 | 内容 |
|---|---|---|---|---|
| p1 | `wf-esp` | 128 MiB | vfat | GRUB、`grubenv`、`vmlinuz-a/b`、`initrd-a/b`、`ab/` 状态、`ab/log/` |
| p2 | `wf-slot-a` | 128 MiB | btrfs | `@sys`、`@wf` |
| p3 | `wf-slot-b` | 128 MiB | btrfs | `@sys`、`@wf` |
| p4 | `wf-shared` | 至盘尾 | btrfs | `@overlay.genNNNN`、`@docker`、`@swap`、`@data` |

不使用 p128（EF02）与 legacy 引导，也不做多主板兼容。

p1 只放数据，不放可执行脚本：FAT32 没有权限位与符号链接、没有日志，且 ESP 上的脚本不随槽回滚。


## 尺寸依据

实测基线取自 ImmortalWrt 25.12.2 x86-64：

| 项 | 实测值 |
|---|---|
| `rootfs.tar.gz` | 10.1 MiB |
| 解压后 rootfs | 26.9 MiB / 1078 文件 |
| 4K 块占用 | 31 MiB |
| `zstd:6` 压缩后 | 10.3 MiB |
| `generic-kernel.bin` | 7.5 MiB |

**p1 = 128 MiB**

| 项 | 估算 |
|---|---|
| `BOOTX64.EFI` + GRUB 模块 | 3–6 MiB |
| `vmlinuz-a/b`（各 9–11 MiB） | 18–22 MiB |
| `initrd-a/b`（各 2–3 MiB） | 4–6 MiB |
| `grubenv`、槽状态、日志 | < 1 MiB |
| 合计峰值 | 约 31 MiB |

余量约 4×。构建期断言：p1 内容 ≤ 64 MiB，否则提升到 256 MiB。

**p2 = p3 = 128 MiB**

- 相对 26.9 MiB 为 4.7×（未压缩），相对 10.3 MiB 为 12×（`zstd:6` 后）
- 2 的幂对齐，便于断言与人工核算
- 运行期只读，写入仅发生在升级时

**p4 = 至盘尾**

镜像内预建 64 MiB，首次启动 grow 到盘尾后 `btrfs filesystem resize max`。

## 文件系统参数

| 分区 | `mkfs` 参数 | 理由 |
|---|---|---|
| p2 / p3 | `mkfs.btrfs -m dup -d single` | 元数据约 4–8 MiB，换槽内静默损坏可恢复 |
| p4 | `mkfs.btrfs -m single -d single` | docker 层会撑大元数据，不复制 |

挂载参数：

| 挂载点 | 参数 |
|---|---|
| `@sys` | `ro,noatime,compress=zstd:6` |
| `@wf` | `ro,noatime` |
| `@overlay.genN` | `rw,noatime,compress=zstd:6,discard=async` |
| `@docker` | `rw,noatime,nodatacow,nodatasum` |
| `@swap` | `rw,noatime,nodatacow,nodatasum` |
| `@data` | `rw,noatime,compress=zstd:3` |

`compress=` 由文件系统**首次挂载**决定，因此先挂 p4 写层再挂只读基座。

## 子卷清单

- p2 / p3：`@sys`、`@wf`
- p4：`@overlay.genNNNN`（含 `upper/`、`work/` 两个普通目录）、`@docker`、`@swap`、`@data`

约束：**全部为顶级子卷**，不存在二级或嵌套子卷。
`@docker`、`@swap` 必须独立，否则快照会丢失其内容且活动 swapfile 会让快照失败。

## 首启扩容

1. `sfdisk` 读取分区表
2. 整表写回，把 p4 末端推到盘尾
3. `partx -u` 重新读取
4. `btrfs filesystem resize max` 扩展 p4

结论写入 p1 日志：`done` / `already-full` / `missing-sfdisk` / `fail`。

## 断言

- p1 内容峰值 ≤ 64 MiB
- p2 / p3 使用率 ≤ 50%
- `btrfs subvolume list` 中所有条目 top level 一致（无嵌套）
- `mkfs` 参数与上表逐字一致

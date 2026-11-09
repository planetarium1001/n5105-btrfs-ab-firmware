# 冲突检测与载荷契约

[English](conflicts-payload.md) | **简体中文**

## 概述

更新会整体替换 `@sys` 树，而可写层中可能存在用户修改过的同名文件。
本文定义这些重叠如何检测，以及升级载荷如何校验。

## 三方比对

| 符号 | 含义 |
|---|---|
| `A` | 旧槽 `@sys` 中的文件（基线） |
| `B` | 新槽 `@sys` 中的文件（新默认） |
| `U` | 可写层中的同名文件（用户版本） |

```
UpstreamChanged = { f : A[f] != B[f] }
UserChanged     = { f : U 存在 且 U[f] != A[f] }
Conflicts       = UpstreamChanged ∩ UserChanged
```

- 比较使用内容哈希，不使用 mtime 或 size
- 基线取自旧 `@sys` 的真实内容，不取自版本号
- 必须识别 whiteout（`0:0` 字符设备）与目录级 `opaque` 标记，
  否则“用户删除了该文件”会从报告中消失

## 处置

| 情形 | 动作 |
|---|---|
| `U` 不存在，`B` 已改 | 采用 `B` |
| `U` 存在，`B` 未改 | 保留 `U` |
| `U` 存在，`B` 也改 | 保留 `U` 并记录冲突 |
| `U` 存在，`B` 已删除 | 标为高危，要求人工确认 |

冲突不阻断更新，也不阻断启动。

## uci 的边界

`/etc/config/*` 下的文件不做逐行合并：uci 有自己的语法，文本合并会产生无法加载的配置。

上游新增默认项通过幂等的 `/etc/uci-defaults/` 脚本引入：只补缺失项，执行后自删。

因此文件级冲突检测只覆盖非 uci 的用户文件。

## 载荷契约

| 成员 | 来源 | 体积 |
|---|---|---|
| `rootfs.tar.gz` | 官方镜像站 | 10.1 MiB |
| `kernel.bin` | 官方镜像站 | 7.5 MiB |
| `initramfs.cpio.gz` | 本项目构建 | 约 2 MiB |
| `wf.tar` | 本项目构建 | 小于 1 MiB |
| `manifest.json` | 本项目生成 | 小于 4 KiB |

升级载荷约 20 MiB。整盘镜像仅用于首次安装。

`manifest.json` 记录每个成员的大小与 sha256，以及 `format` 与 `rootfs` 版本。

## 校验顺序

任一步失败即中止更新：

1. `manifest.json` 可解析且 `format` 匹配
2. 每个成员存在且 sha256 与 manifest 一致
3. `initramfs.cpio.gz` 内 `btrfs.ko` 的 vermagic 与 `kernel.bin` 一致
4. p4 剩余空间不低于 5%
5. 冲突报告已生成

失败时 `platform_check_image` 返回 74，即使 `sysupgrade -F` 也拒绝写入。

## 构建输入与 adapter

CI 不编译内核，直接消费官方产物：

- `immortalwrt-<ver>-x86-64-rootfs.tar.gz`
- `immortalwrt-<ver>-x86-64-generic-kernel.bin`
- `kmods/<kernel-ver>-<hash>/kmod-fs-btrfs.apk` 及其依赖

预检：kmods 目录名中的 hash 必须与 `kernel` 包版本中的 hash 相同，否则构建失败。

载荷来源做成 adapter：

| Adapter | 行为 |
|---|---|
| `upstream` | 下载官方 rootfs 与 kernel（默认） |
| `selfbuild` | 使用本地构建的 rootfs 与 kernel（保留接缝，暂未实现） |

切换 adapter 不改变装配层与 initramfs。

## 为什么 btrfs 以模块形式提供

25.12.2 的 `config.buildinfo` 中没有 `CONFIG_KERNEL_BTRFS_FS`，默认镜像 manifest 的
227 个包中也没有 btrfs。因此 btrfs 只能由 initramfs 加载 `kmod-fs-btrfs` 提供，
这是上游消费路线的前提。

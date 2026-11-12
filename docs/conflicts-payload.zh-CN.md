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

| 成员 | 来源 | 实测体积 |
|---|---|---|
| `rootfs.tar.gz` | 官方镜像站 | 10 587 455 B（10.1 MiB） |
| `kernel.bin` | 官方镜像站 | 7 709 696 B（7.35 MiB） |
| `initramfs.cpio.gz` | 本项目构建 | 3 056 055 B（2.9 MiB） |
| `platform.tar` | 本项目构建 | 1 484 800 B（1.42 MiB） |
| `boot.tar` | 本项目构建 | 655 360 B（640 KiB） |
| `manifest.json` | 本项目生成 | 1 396 B（1.4 KiB） |

六个成员合计 23 494 762 B；装它们的那个 payload tar 是 23 500 800 B（22.41 MiB），差额是 tar 的块填充。
所以升级载荷是刚过 20 MiB；整盘镜像仅用于首次安装。

这些体积是量出来的，不是估的：它们是已发布的 `v0.0.8` 载荷成员，在你自己的副本上跑
`tar -tvf n5105-ab-<upstream>-upgrade.tar` 会打印同样的列表。体积逐发布变化，形状不变。

`manifest.json` 记录每个成员的大小与 sha256，以及 `format`、`rootfs` 版本、`platform` 版本与
`kernel` 包标识。它的 `bootloader` 块在下一节。

## 引导器成员

`boot.tar` 是让升级能把引导器一起带上去的那个成员。它里面只有两个文件，没有别的内容：

| `boot.tar` 内的路径 | 是什么 |
|---|---|
| `EFI/BOOT/BOOTX64.EFI` | 上游的 standalone GRUB EFI 本体，与写进 ESP 的字节完全一致 |
| `boot/grub/grub.cfg` | 本项目的槽菜单，由 `scripts/ci/grub-render.sh` 从 `scripts/ci/grub.cfg.in` 渲染，且只有通过五条渲染规则才会被带上 |

manifest 用一个 `bootloader` 块描述这些字节，这样升级工具不必猜自己要写什么：

| 字段 | 含义 | 谁拿它做事 |
|---|---|---|
| `member` | 装这两个文件的 tar 成员，即 `boot.tar` | `ab-upgrade` |
| `loader` | 加载器在该成员内的路径 | `ab-upgrade`，就找这一个文件 |
| `menu` | 菜单在该成员内的路径 | `ab-upgrade`，同样 |
| `loader_bytes` | 加载器的字节数 | ESP 空间规则：必须空出 `loader_bytes / 1024 + 4096` KiB，`--check` 与真正写入用的是同一个数 |
| `loader_sha256` | 加载器的摘要 | 设备真正信的那个事实：替换任何东西之前与 ESP 上的字节比对，替换之后再比对一次 |
| `menu_sha256` | 菜单的摘要 | 同上，针对 `boot/grub/grub.cfg` |
| `grub_version` | GRUB 的版本串，从加载器二进制里读出来（`GNU GRUB  version` 后面那个 token），读不到就是 `unknown` | 没有人拿它做判断：它是摘要旁边给人看的证据 |
| `source_image` | 这些字节出自哪个上游镜像 | 运行期没人用；它是发布记录的出处 |
| `source_sha256` | 那个镜像的摘要 | 同上 |

没有 boot 源时构建出来的载荷没有 `boot.tar`，manifest 里的 `bootloader` 写的是 `null`。那是合法载荷——ESP 本来就好的机器
继续用它现在的加载器——而 `ab-upgrade` 会把这件事说在控制台上（`bootloader absent-in-payload`），
不会闷着装上去。要把一次构建标记成“必须带引导器”用 `CI_REQUIRE_BOOTLOADER=1`，缺 boot 源就变成
构建失败。

**这个成员只有一处定义：`scripts/ci/boot-member.sh`。** 这段 fragment 被两个构建器 source：
`scripts/ci/payload-build.sh`（S5 测试装的那个载荷）与 `scripts/ci/assemble.sh`（发布真正发出去的
载荷）。两者都调 `ci_boot_member_stage`，manifest 的块也都来自它。

共用不是为了整齐，而是修一个真发生过的缺陷：当只有测试载荷带 `boot.tar` 时，发出去的载荷仍让升级过的机器
引导它刷机时那份 GRUB——因为 CI 验的是另一个构建器，缺陷看起来是修好的。只在一个构建器里修过、另一个
构建器里还活着的成员，等于没修，所以是一处定义而不是两处。发布装配还会在 fragment 没返回成员时直接让
构建失败，而且这个检查没有关闭开关。

想人工核对一个载荷的身份、不碰真机，在仓库根目录执行：

```sh
mkdir -p /tmp/payload
tar -xf n5105-ab-<upstream>-upgrade.tar -C /tmp/payload boot.tar manifest.json
tar -xf /tmp/payload/boot.tar -C /tmp/payload
bash scripts/ci/grub-render.sh --check-loader /tmp/payload/EFI/BOOT/BOOTX64.EFI /tmp/payload/manifest.json
```

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

# 冲突检测与载荷契约

## 三方比对

升级会替换整棵 `@sys`，而 `@overlay` 的 upper 里可能有用户改过的同名文件。

定义：

- `A` = 旧槽 `@sys` 中的文件（基线）
- `B` = 新槽 `@sys` 中的文件（新默认）
- `U` = upper 中的同名文件（用户版本）

判定：

```
UpstreamChanged = { f : A[f] != B[f] }
UserChanged     = { f : U 存在 且 U[f] != A[f] }
Conflicts       = UpstreamChanged ∩ UserChanged
```

- 以**内容哈希**判定，不使用 mtime 或 size
- 基线必须来自旧槽 `@sys` 的真实内容，不来自版本号
- 需同时识别 whiteout（`0:0` 字符设备）与目录级 `opaque` 标记，否则"用户删除了某文件"会从报告中消失

## 处置

| 情形 | 处置 |
|---|---|
| `U` 不存在，`B` 改了 | 采用 `B` |
| `U` 存在，`B` 未改 | 保留 `U` |
| `U` 存在，`B` 也改 | 保留 `U`，写入冲突报告 |
| `U` 存在，`B` 已删除 | 高危，单列并要求人工确认 |

冲突**不阻断**升级，也不阻塞启动。

## uci 的边界

`/etc/config/*` 不做文件级合并。uci 是自定义语法，行级合并会产出无法加载的配置。

上游新增默认项通过 `/etc/uci-defaults/` 幂等脚本补齐：缺项才写、执行后自删、重复执行无副作用。

文件级冲突检测只覆盖非 uci 的用户文件。

## 载荷契约

| 成员 | 来源 | 体积 |
|---|---|---|
| `rootfs.tar.gz` | 官方镜像站 | 10.1 MiB |
| `kernel.bin` | 官方镜像站 | 7.5 MiB |
| `initramfs.cpio.gz` | 本项目构建 | 约 2 MiB |
| `wf.tar` | 本项目构建 | < 1 MiB |
| `manifest.json` | 本项目生成 | < 4 KiB |

升级载荷约 20 MiB。整盘镜像只在首次刷机时使用。

`manifest.json` 记录每个成员的大小与 sha256，以及 `format` 与 `rootfs` 版本。

## 校验

顺序如下，任一失败即中止：

1. `manifest.json` 可解析，`format` 匹配
2. 每个成员存在且 sha256 与 manifest 一致
3. `initramfs.cpio.gz` 内 `btrfs.ko` 的 vermagic 与 `kernel.bin` 版本一致
4. p4 剩余空间 ≥ 5%
5. 冲突报告生成完毕

失败时 `platform_check_image` 返回 74，使 `sysupgrade -F` 也无法写入。

## 构建输入与 adapter

CI 不编译内核，直接消费官方产物：

- `immortalwrt-<ver>-x86-64-rootfs.tar.gz`
- `immortalwrt-<ver>-x86-64-generic-kernel.bin`
- `kmods/<kernel-ver>-<hash>/kmod-fs-btrfs.apk` 及其依赖

预检：kmod 目录的 hash 必须与 `kernel` 包版本中的 hash 相同，否则构建失败。

载荷来源做成 adapter：

| adapter | 行为 |
|---|---|
| `upstream` | 下载官方 rootfs 与 kernel（默认） |
| `selfbuild` | 使用自建 rootfs 与 kernel（保留接缝，暂不实现） |

切换 adapter 不改变装配层与 initramfs。

## 官方内核对 btrfs 的态度

`config.buildinfo` 中无 `CONFIG_KERNEL_BTRFS_FS`，默认镜像 227 个包里也没有 btrfs。
因此 btrfs 只能以 `kmod-fs-btrfs` 形式由 initramfs 加载，这是路线 A 的前提。

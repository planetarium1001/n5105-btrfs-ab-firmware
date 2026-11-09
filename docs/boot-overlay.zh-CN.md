# 引导链与分层根

[English](boot-overlay.md) | **简体中文**

## 概述

运行期根由 overlayfs 合成：活动槽的两个只读层，加上共享分区上的一个可写层。

## 引导顺序

1. GRUB 从 p1 读取槽状态与 `grubenv`，选择内核与 initrd。
2. initramfs 按 PARTLABEL 定位 p2、p3、p4，先挂载 p4 可写层，再挂载槽内只读层。
3. overlayfs 合成根。
4. `switch_root` 进入系统，p1 挂载到 `/boot`。

## 层职责

| 层 | 子卷 | 模式 | 内容 | 写入方 |
|---|---|---|---|---|
| 上游系统 | `@sys` | ro | 上游 rootfs，逐字节一致 | 仅升级 |
| 平台 | `@wf` | ro | `ab-slot`、init.d 钩子、修复工具 | 仅升级 |
| 用户状态 | `@overlay.genN` | rw | 配置、已安装软件、用户文件 | 运行期 |

`@wf` 与槽版本绑定：升级时写入，回退时随槽退回。

## 挂载合成

```
/ = overlay(
      lowerdir=/mnt/wf:/mnt/sys,
      upperdir=/mnt/p4/@overlay.gen0002/upper,
      workdir=/mnt/p4/@overlay.gen0002/work,
      index=off,metacopy=off,redirect_dir=off )
```

- `lowerdir` 顺序固定为 `@wf:@sys`，平台层优先
- `index=off` 避免 in-use 排他锁，以及回退后残留的 index 项
- 不使用 `volatile` 选项

## 挂载顺序

1. 以 `rw,compress=zstd:6,discard=async` 挂载 p4 的 `@overlay.genN`
2. 以 `ro` 挂载 `@wf`
3. 以 `ro` 挂载 `@sys`
4. 断言 `/proc/mounts` 中该挂载行包含 `compress=`

先挂 p4 的原因：`compress=` 只由文件系统的首次挂载生效，若先挂只读层，该参数不会进入内核。

## 平台层如何生效

`@wf` 按最终路径组织：

- `/usr/sbin/ab-slot`
- `/etc/init.d/ab-boot`
- `/etc/init.d/ab-commit`
- `/etc/uci-defaults/`

overlayfs 会合并目录，procd 从合并视图读取 `/etc/init.d/*`，钩子正常执行，而 `@sys` 不受改动。

## GRUB 渲染断言

渲染结果必须全部满足，否则构建失败：

- 包含 `set default=${committed_entry}`
- `save_env` 只传变量名，形式为 `save_env -f <grubenv> ab_try`
- 不得出现 `save_env.*ab_try=`
- 不使用 `&&`、`||`、`${x:-y}`
- 无未替换的模板记号

## 故障与降级启动

| 故障 | 行为 |
|---|---|
| 内核或 initrd 加载失败 | GRUB 内联重试，再 `set fallback` 回到已提交槽 |
| initramfs 阶段失败 | 记录日志并重启；`ab_try` 已被消费，回到已提交槽 |
| 健康检查失败 | 放弃待提交槽，回到已提交槽 |
| p4 挂载失败 | 重试，再以 `recovery` 只读挂载，最后用 tmpfs 上层降级启动 |

降级启动时 `upperdir` 位于 tmpfs：系统可用但不持久。
`ab-slot status` 仍可使用，因为 `@wf` 在 p2/p3 上，不在 p4。

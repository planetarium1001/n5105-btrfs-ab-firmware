# N5105 Btrfs A/B Firmware

N5105 v5 单板的 ImmortalWrt 定制固件：A/B 双根 + btrfs 文件系统。

本项目只做系统层——AB 根与 btrfs。

## 定位

- 目标硬件：N5105 v5，x86-64，UEFI，4× Intel i226-V
- 系统内容：与上游 ImmortalWrt 逐字节一致，不预装任何额外软件
- 自有内容：只存在于构建层、引导层与 `@wf` 平台层
- 引导：EFI-only，不含 legacy/BIOS 与多主板兼容

## 磁盘布局

| 分区 | 大小 | 文件系统 | 内容 |
|---|---|---|---|
| p1 | 128 MiB | vfat | GRUB、槽状态、启动日志 |
| p2 | 128 MiB | btrfs | 槽 A：`@sys` + `@wf` |
| p3 | 128 MiB | btrfs | 槽 B：`@sys` + `@wf` |
| p4 | 至盘尾 | btrfs | `@overlay.genNNNN`、`@docker`、`@swap`、`@data` |

- `@sys`：上游 rootfs，只读
- `@wf`：平台工具，随槽版本绑定，只读
- `@overlay.genNNNN`：全部可写状态，两槽共享

## 启动链

1. GRUB 从 p1 读槽状态，选择内核与 initrd
2. initramfs 挂载 p4 写层与槽内只读层
3. 合成 overlayfs 根：`lowerdir=@wf:@sys`、`upperdir=@overlay.genN/upper`
4. `switch_root` 进入系统

## 升级与回退

- 升级写入非活动槽，不触碰运行中的系统
- 写层按代号推进：快照当前代号生成新代号，全程不重命名
- 首次启动失败一次即回退到已提交槽
- 健康检查通过才提交，否则放弃并回到旧槽
- 只能回滚一代

## 构建

- CI 从官方镜像站消费 `rootfs.tar.gz`、`kernel.bin` 与 kmod，组装自有 initramfs 与整盘镜像
- 不编译内核；升级载荷约 20 MiB
- 产物：整盘镜像（首次刷机）、升级载荷（日常更新）

## 仓库边界

- 只发布代码与文档
- 工作流、技能、AGENTS.md、知识库、任务记录均不入库

## 状态

设计阶段。分区几何、启动链、升级事务已定稿，实施按 S0–S6 推进。

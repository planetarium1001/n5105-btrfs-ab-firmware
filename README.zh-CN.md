# N5105 Btrfs A/B 固件

基于 ImmortalWrt 的 N5105 v5 单板固件，在 btrfs 上实现 A/B 双根更新。

[English](README.md) | **简体中文**

本项目只负责系统层：A/B 引导槽与 btrfs 布局。
应用层打包与配置不在范围内。

## 范围

| 项目 | 取值 |
|---|---|
| 目标硬件 | N5105 v5，x86-64，UEFI，4× Intel i226-V |
| 基础系统 | ImmortalWrt，rootfs 与上游逐字节一致 |
| 项目自有内容 | 仅构建层、引导层与 `@platform` 平台层 |
| 引导 | 仅 UEFI；不支持 legacy/BIOS 与多主板 |

## 磁盘布局

| 分区 | 大小 | 文件系统 | 内容 |
|---|---|---|---|
| p1 | 128 MiB | vfat | GRUB、槽状态、启动日志 |
| p2 | 128 MiB | btrfs | 槽 A：`@sys` + `@platform` |
| p3 | 128 MiB | btrfs | 槽 B：`@sys` + `@platform` |
| p4 | 至盘尾 | btrfs | `@overlay-<版本>`、`@docker`、`@swap`、`@data` |

- `@sys` —— 上游 rootfs，只读
- `@platform` —— 平台工具，随槽版本绑定，只读
- `@overlay-<版本>` —— 全部可写状态，两槽共享

## 启动链

1. GRUB 从 p1 读取槽状态，选择内核与 initrd。
2. initramfs 先挂载 p4 可写层，再挂载槽内只读层。
3. overlayfs 合成根：`lowerdir=@platform:@sys`，`upperdir=@overlay-<version>/upper`。
4. `switch_root` 进入系统。

## 更新与回退

- 更新写入非活动槽，不修改运行中的系统。
- 可写层按代号推进：快照当前代号，全程不重命名。
- 首次启动失败一次即回退到已提交槽。
- 健康检查通过后才提交新槽。
- 回退深度为一代。

## 构建

- CI 从官方镜像站获取 `rootfs.tar.gz`、`kernel.bin` 与内核模块，组装 initramfs 与整盘镜像。
- 不编译内核；升级载荷约 20 MiB。
- 产物：首次安装用整盘镜像，日常更新用升级载荷。

## 仓库策略

- 只发布源代码与文档。
- 工作流配置、Agent 指令、知识库与任务记录均保留在本地。

## 测试

```
./tests/run.sh                  # 全部模块，默认并行
./tests/run.sh --module design  # 单个模块
./tests/run.sh --jobs 8         # 限定并行度
./tests/run.sh --list           # 列出已发现的用例
```

测试位于 `tests/modules/<module>/test_*.sh`，一个模块一个关注点。
每个测试是独立进程，模块之间并行执行，单个失败不会掩盖其它失败。

## 文档

- [docs/](docs/README.zh-CN.md) —— 设计文档

## 状态

设计阶段。分区几何、启动链与更新事务已定稿，实施按 S0–S6 推进。

## 版本管理

格式：`MAJOR.MINOR.PATCH`。

- `MAJOR` 恒为 `0`：项目处于试验阶段，仍可能出现破坏性改动。
- `MINOR` 表示项目目标彻底达成，只有那时才升到 `0.1.0`。
- `PATCH` 表示阶段性里程碑，目标尚未达成。

当前版本：`0.0.5` —— 流水线产出真载荷，并用设备端同一套校验器验证；打 tag 会发布镜像
与对应载荷。安装、提交、注入失败回退、升级、回收、可写分区降级全部在 QEMU 中跑过。

## 许可证

- 构建工具与项目自有代码：[MIT](LICENSES/MIT.txt)
- 源自上游 OpenWrt 的文件：[GPL-2.0-only](LICENSES/GPL-2.0-only.txt)

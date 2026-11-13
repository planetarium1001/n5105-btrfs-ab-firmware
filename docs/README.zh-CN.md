# 文档

[English](README.md) | **简体中文**

每篇文档只讲一个主题。所有数字均有实测依据或明确理由。

| 文档 | 内容 |
|---|---|
| [ci-pipeline.zh-CN.md](ci-pipeline.zh-CN.md) | 每个 workflow 文件与何时该跑它、五个阶段（各自证明什么、失败代价）、产物对照表、怎么读一个 run 页面，以及怎么在本地复现一个阶段 |
| [ci-release-lines.zh-CN.md](ci-release-lines.zh-CN.md) | 两条发布线（`v*` 与裸版本号）、一个 tag 必须证明什么、每夜的上游 watch，以及一次真实发布的复盘 |
| [ci-text-contract.zh-CN.md](ci-text-contract.zh-CN.md) | CI 对人说的每一句话的 7 条规则：workflow/job/step 标签、input 描述、各类摘要、Issue 与 PR 正文、release 标题——以及让文本改动碰不到运行行为的结构指纹 |
| [device-matrix.zh-CN.md](device-matrix.zh-CN.md) | 通过 SSH 驱动真机跑版本矩阵：每条断言证明什么、续跑文件、结果三态，以及保住可启动槽的红线 |
| [partitions.zh-CN.md](partitions.zh-CN.md) | 分区几何、GPT PARTNAME 与文件系统 LABEL 命名、尺寸依据、`mkfs` 与挂载参数、子卷、首启扩容 |
| [boot-overlay.zh-CN.md](boot-overlay.zh-CN.md) | 引导顺序、层职责、挂载合成与顺序、平台层注入、GRUB 断言、降级启动 |
| [lifecycle.zh-CN.md](lifecycle.zh-CN.md) | 代号模型、状态文件、更新事务、健康检查、回收、日志、命令 |
| [conflicts-payload.zh-CN.md](conflicts-payload.zh-CN.md) | 三方比对、处置、uci 边界、载荷契约、引导器成员、校验、构建输入 |
| [install.zh-CN.md](install.zh-CN.md) | 写镜像、首次开机、控制台、升级一台运行中的机器（`ab-upgrade` 的选项与退出码、救援被写坏的引导器）、怎么读 `ab-slot status`、排障 |
| [update.zh-CN.md](update.zh-CN.md) | 从发布 feed 更新一台机器：配置文件、三个版本号（`base`、`kernel`、`platform`）、`ab-upgrade --feed-check` 与 `--feed`、五个风险级别与各自的确认强度、`UPDATE_PIN`、完整的 `reason=` 表，以及发布方怎么自建 feed |
| [network.zh-CN.md](network.zh-CN.md) | 首启网络生成、出厂默认值（WAN 口、桥端口、LAN 网段）、怎么改、WAN SSH 例外 |
| [debug-ssh.zh-CN.md](debug-ssh.zh-CN.md) | 人工交互调试入口：触发、连接、已备好的产物、会话时长、安全、为什么它不是门禁 |
| [backup.zh-CN.md](backup.zh-CN.md) | 三种产物各自能恢复到多大的盘、整盘镜像为什么在更小的盘上写入即失败、恢复决策树（路径 A–D），以及 `ab-backup` / `ab-restore` 往包里装什么 |

## 约定

- 阈值与日志字段是契约，改动必须同步更新 `scripts/check_design.py`
- 文档描述约束与判据，不复述实现细节
- 链接使用相对路径且必须可解析，由 `python3 scripts/check_design.py links` 校验
- 英文为主文档，每篇旁边有对应的 `*.zh-CN.md` 译文

## 校验

```
python3 scripts/check_design.py all
```

单项检查：`partitions`、`esp-data-only`、`overlay-layers`、`generation-model`、
`gc-policy`、`log-ring`、`conflict-model`、`payload-contract`、`links`、`text`、
`retired-names`、`debug-ssh`、`workflow-expressions`。

## 相关

- 项目概览：[../README.zh-CN.md](../README.zh-CN.md)
- 许可证：[../LICENSES/](../LICENSES/)

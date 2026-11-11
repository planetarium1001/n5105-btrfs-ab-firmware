# 文档

[English](README.md) | **简体中文**

每篇文档只讲一个主题。所有数字均有实测依据或明确理由。

| 文档 | 内容 |
|---|---|
| [ci-pipeline.zh-CN.md](ci-pipeline.zh-CN.md) | 三条 CI workflow、五个阶段（各自证明什么、失败代价）、产物对照表，以及怎么读一个 run 页面 |
| [device-matrix.zh-CN.md](device-matrix.zh-CN.md) | 通过 SSH 驱动真机跑版本矩阵：每条断言证明什么、续跑文件、结果三态，以及保住可启动槽的红线 |
| [partitions.zh-CN.md](partitions.zh-CN.md) | 分区几何、GPT PARTNAME 与文件系统 LABEL 命名、尺寸依据、`mkfs` 与挂载参数、子卷、首启扩容 |
| [boot-overlay.zh-CN.md](boot-overlay.zh-CN.md) | 引导顺序、层职责、挂载合成与顺序、平台层注入、GRUB 断言、降级启动 |
| [lifecycle.zh-CN.md](lifecycle.zh-CN.md) | 代号模型、状态文件、更新事务、健康检查、回收、日志、命令 |
| [conflicts-payload.zh-CN.md](conflicts-payload.zh-CN.md) | 三方比对、处置、uci 边界、载荷契约、校验、构建输入 |
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
`gc-policy`、`log-ring`、`conflict-model`、`payload-contract`、`links`、`text`、`debug-ssh`。

## 相关

- 项目概览：[../README.zh-CN.md](../README.zh-CN.md)
- 许可证：[../LICENSES/](../LICENSES/)

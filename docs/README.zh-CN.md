# 文档

[English](README.md) | **简体中文**

每篇文档只讲一个主题。所有数字均有实测依据或明确理由。

| 文档 | 内容 |
|---|---|
| [partitions.zh-CN.md](partitions.zh-CN.md) | 分区几何、GPT PARTNAME 与文件系统 LABEL 命名、尺寸依据、`mkfs` 与挂载参数、子卷、首启扩容 |
| [boot-overlay.zh-CN.md](boot-overlay.zh-CN.md) | 引导顺序、层职责、挂载合成与顺序、平台层注入、GRUB 断言、降级启动 |
| [lifecycle.zh-CN.md](lifecycle.zh-CN.md) | 代号模型、状态文件、更新事务、健康检查、回收、日志、命令 |
| [conflicts-payload.zh-CN.md](conflicts-payload.zh-CN.md) | 三方比对、处置、uci 边界、载荷契约、校验、构建输入 |

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
`gc-policy`、`log-ring`、`conflict-model`、`payload-contract`、`links`、`text`。

## 相关

- 项目概览：[../README.zh-CN.md](../README.zh-CN.md)
- 许可证：[../LICENSES/](../LICENSES/)

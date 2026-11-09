# 文档索引

本目录保存设计文档。每篇只讲一件事，数字均有实测或明确依据。

| 文档 | 内容 |
|---|---|
| [partitions.md](partitions.md) | 四分区几何、尺寸依据、`mkfs` 与挂载参数、子卷清单、首启扩容 |
| [boot-overlay.md](boot-overlay.md) | 引导流程、三层职责、挂载参数与顺序、平台层注入、GRUB 渲染断言、降级 |
| [lifecycle.md](lifecycle.md) | 代号模型、状态文件、升级时序、健康检查、回收、日志、命令 |
| [conflicts-payload.md](conflicts-payload.md) | 三方比对、处置、uci 边界、载荷契约、校验、构建输入与 adapter |

## 约定

- 阈值与判读串一经写入即为契约，改动需要同步更新检查脚本
- 文档不与代码重复描述实现细节，只描述约束与判据
- 链接一律使用相对路径，且必须可解析

## 相关

- 项目概览：[../README.md](../README.md)
- 许可证：[../LICENSES/](../LICENSES/)

# 文档

**中文** | [English](README.md)

十三篇文档，每篇是它自己主题的唯一来源。里面的每个数字都是实测的，或者带有明确理由。

每个阈值、日志字段与契约都由 `python3 scripts/check_design.py all` 断言。每篇还都遵守
[style.zh-CN.md](style.zh-CN.md)。

要用这套固件，从 [quickstart.zh-CN.md](quickstart.zh-CN.md) 开始。要改它，读
[architecture.zh-CN.md](architecture.zh-CN.md) 与 [ci.zh-CN.md](ci.zh-CN.md)。

## 使用

| 文档 | 内容 |
|---|---|
| [quickstart.zh-CN.md](quickstart.zh-CN.md) | 最短路径：写镜像、启动、装一个包、升一次级、回退一次——五步，每步给出命令与该步必须产生的输出 |
| [install.zh-CN.md](install.zh-CN.md) | 写镜像、控制台上的首启、网络默认值、验收清单、升级运行中的系统、抢救被写坏的引导器 |
| [update.zh-CN.md](update.zh-CN.md) | 从 release feed 升级：配置文件、三个版本号、风险级别、每个 `reason=` token、状态字段参考、软件包跟随与回滚 |
| [plugins.zh-CN.md](plugins.zh-CN.md) | 声明自己的包来源：`plugin.conf` 的字段、`plugins list` / `check` / `apply` 与调试用的 `repos`、三条护栏、源不可达意味着什么、怎么关掉一个插件，以及默认关着的 iStore 示例 |
| [plugins-catalog.zh-CN.md](plugins-catalog.zh-CN.md) | 我们在真机上跑过的插件配方：一张表说清每份配方装什么、读哪些源，iStore 一节给出三个 feed、它的 key、它自己的依赖拉进来的包以及怎么关回去，最后是这份清单的边界 |
| [backup.zh-CN.md](backup.zh-CN.md) | 三种产物与各自能恢复到什么介质、整盘镜像为什么装不进更小的盘，以及恢复决策树 |
| [network.zh-CN.md](network.zh-CN.md) | 首启网络生成、随镜像发布的默认值、怎么改它们，以及 WAN SSH 例外 |
| [troubleshooting.zh-CN.md](troubleshooting.zh-CN.md) | 先读什么、每种现象意味着什么，以及本项目决定不去改变的行为 |

## 修改

| 文档 | 内容 |
|---|---|
| [architecture.zh-CN.md](architecture.zh-CN.md) | 分区几何、文件系统与子卷、启动链、p4 首启扩容、槽位状态机、升级事务、健康检查、回收、日志、冲突检测与 payload 契约 |
| [ci.zh-CN.md](ci.zh-CN.md) | 每个工作流文件与何时跑它、五个阶段、跨版本阶段与升级闸门、产物、本地复现、两条发布线、每日上游 watch、交互式调试，以及 CI 文本契约 |
| [device-matrix.zh-CN.md](device-matrix.zh-CN.md) | 通过 SSH 驱动真机跑版本矩阵：每条断言证明什么、续跑文件、结果状态，以及保住可启动槽位的红线 |
| [style.zh-CN.md](style.zh-CN.md) | 一页要遵守的规则：长度上限、块布局、成对规则、检查器跳过什么，以及 `scripts/check_docs_style.py` 的选项 |

## 约定

- 阈值、日志字段与 payload 成员都是契约。改一项意味着在同一次提交里改
  `scripts/check_design.py` 与断言它的测试。
- 链接是相对路径且必须能解析；`python3 scripts/check_design.py links` 校验这一点。
- 英文是正本，每篇旁边都有 `*.zh-CN.md` 译本，且章节结构一致。
- 命令可直接复制执行；占位符写成 `<angle-brackets>`。

## 检查

```sh
python3 scripts/check_design.py all
./tests/run.sh --module docs
```

单项设计检查：

- `partitions`、`esp-data-only`、`overlay-layers`、`generation-model`
- `gc-policy`、`log-ring`、`conflict-model`、`payload-contract`
- `links`、`text`、`retired-names`、`debug-ssh`
- `workflow-expressions`、`docs-style`

## 另见

- 项目总览：[../README.zh-CN.md](../README.zh-CN.md)
- 许可证：[../LICENSES/](../LICENSES/)

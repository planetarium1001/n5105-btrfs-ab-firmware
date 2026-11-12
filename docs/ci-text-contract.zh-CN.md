# CI 文本契约

[English](ci-text-contract.md) | **简体中文**

流水线在四个地方对人说话：run 页面、每个 stage 留下的日志块、上游巡检打开的 Issue 与 PR、
以及 release 页面。这四处都是**赶时间**读的——刚红了一条 run 的人，或者正要判断某个 release
能不能信的人。一个每次都把话说成同一形状的标签，比"第一次说得好、第二次换一种说法"的标签
快得多。

这一页就是那份契约：7 条规则，其中 6 条由
`tests/modules/ci/test_ci_text_conventions.sh` 断言。第 7 条——这句话读起来顺不顺——需要人，
所以它有自己的一节，附上该问的问题。

## 作用范围

范围是 CI 读者能看到的全部文本，以及渲染它们的文件：

| 路径 | 承载什么 |
|---|---|
| `.github/workflows/*.yml` | workflow、job、step 的标签；input 描述 |
| `.github/actions/*/action.yml` | 6 个 composite 的同类文本 |
| `scripts/ci/*.sh` | 它们打印的串：stage summary、report、diagnostics、Issue 正文、PR 正文、release notes |
| `docs/*.zh-CN.md` | 每页的中文译文。这是唯一允许中文的地方 |

代码注释不在契约范围内：注释是给改这个文件的人读的，不是给读 run 的人读的。
`tests/modules/` 下那些"证明流水线仍能处理非英文数据"的 fixture，同样不属于违规。

## 规则 1 - CI 面一律英文

面上每一行非注释文本都是 ASCII。一个混着两种语言的 run 页面更慢扫、也无法 grep；
流水线是工具不是文档，它的读者是值班的人，不是"和我同一母语的人"。

机器判定。断言走上面三类文件、跳过注释行，统计大于 `U+007F` 的字符数。

## 规则 2 - 标签不是句子

名字是标签：结尾不加句点，不用感叹号，前后不留空格。sentence case——首词大写，
其余小写，专有名词除外（`GRUB`、`ESP`、`A/B`、`S3`）。Issue 标题、PR 标题、
release 标题同理。

机器判定：面上每个 `name:`，以及三个渲染出来的标题。

## 规则 3 - 长度上限

| 层级 | 上限 | 原因 |
|---|---|---|
| workflow `name:` | 40 | Actions 侧栏会截断 |
| job `name:` | 40 | job 列表一行一个 |
| step `name:` | 60 | step 列表是页面上最窄的一列 |
| Issue、PR、release 标题 | 80 | 标题在列表视图里会被切 |

超过上限的名字在描述两件事；该拆的是 step，不是上限。

机器判定。

## 规则 4 - 每一层只有一个语法位

每一层一个形状，读者只需要学一次这套词。

- **Workflow。** 能自己起一次 run 的文件是入口点，命名为 `Firmware CI - <角色>`。
  只声明 `workflow_call`、无法自己起 run 的文件，按它覆盖的东西命名：五个 stage 是
  `S<n> <语义>`，其余是短语（`resolve upstream`、`static checks`、`release publish`）。
- **Job。** stage job 是 `S<n> <语义> - <它证明了什么>`；其余 job 是动宾短语
  （`open the pin pull request`、`merge and tag`）。
- **Step。** 只有两种形状。做事的 step 是 `<动词短语>`，首词取流水线自己的动词表；
  开启一个阶段的 step 是 `<标记> - <断言>`，标记只能是 `Boot <n>`、`Phase <n>`、
  `Phase <n><字母>`、`Fixture`、`Preflight`。step 名不带 stage 编号：上面的 job 已经说了。
- **分隔符。** 只有一个：` - `，空格连字符空格。名字里不用括号、冒号、间隔号、破折号。

机器判定：每个 workflow 名对照它的 trigger 检查形状，每个 job、step 名的首词对照两种形状。

## 规则 5 - 固定的 summary 表

summary 是一张表，同一张表出现在哪儿都长一样。表头小写，一共只有五种——不需要第六种，
需要第六种的表在描述读者无法据此行动的东西：

- `stage | verdict | key line | artifact and sha256 | next command`：每个 stage 的 summary 块。
- `stage | verdict | duration | artifact`：report 的跨流水线总表。
- `field | value`：所有键值块——report 事实、pre-publish 检查、release 输入、Issue 事实。
- `job | result`：上游巡检的失败 Issue。
- `artifact | size | sha256`：产物清单——release 钩子与 release notes。

第三个表头容易被写成 `item`，但不用它：`item` 是"一串里的一项"，`field` 才是"键值表的一格"，
而且 `report.sh` 已经在说 `field`。

机器判定：面上每个表头行都必须是这五种之一，内容与大小写一起比。

## 规则 6 - 固定的标题模板

| 对象 | 模板 | 示例 |
|---|---|---|
| Issue，自动发布失败 | `[auto-release] <版本>` | `[auto-release] 25.13.0` |
| PR，pin 变更 | `chore(ci): pin upstream <版本>` | `chore(ci): pin upstream 25.13.0` |
| 自动分支上的提交 | `chore(ci): pin upstream <版本>` | `chore(ci): pin upstream 25.13.0` |
| PR 正文一级标题 | `# Upstream <版本> (pin <旧> -> <新>)` | `# Upstream 25.13.0 (pin 25.12.2 -> 25.13.0)` |
| Release 标题 | 由 publisher 按 `tag-policy` 派生：`v` → `N5105 AB firmware <版本>`，`bare` → `ImmortalWrt N5105 A/B firmware <版本>` | `N5105 AB firmware 0.0.8`、`ImmortalWrt N5105 A/B firmware 25.13.0` |

Issue 标题只带版本号，因为它同时是去重键：同一个故障更新同一条 Issue，
而不是每天新开一条。

模板只有一个主人：`release-publish.yml` 按那条本来就把两条线分开的旗标派生标题，两个调用点
都不传 `title`。两条线的差别在 trigger、tag 形状和谁拥有 `VERSION`——不在调用点上拼出来的标题；
后者等于同一个决定做两次，而两次迟早会漂。

标题不同，是因为发布的东西不同。`v` tag 发的是我们自己的里程碑，用固件名。裸版本号换的是
ImmortalWrt 底座，标题就说清这件事：读者比较两个 release 时，最先需要知道的就是"这个镜像是
基于哪个上游版本"。

release notes 点名证明这次发布的 run，以及那次 run 实际得出的结论。结论从 run 里读，
绝不写成固定句：流水线只被要求跑一个 stage 时，发布页却宣称五个 stage 全过，
是在读者唯一无法自行复核的地方说了假话。

机器判定：两份正文都走真实代码路径渲染出来逐行比对；渲染器还要 grep 一遍，
确认没有硬编码的 stage 结论。

## 规则 7 - 结构与文本分开

文本改动绝不改变实际跑什么。护栏是 `tests/fixtures/ci-structure-fingerprint.txt`：
每个结构 token 一行、排序后存放——job 键、`needs`、`uses` 的 pin、`with` 与 `env` 的键、
`outputs` 键、input 名、artifact 名、`scripts/ci/*.sh` 的标识符与开关，以及每一个
`S1-RESULT=` … `S5-RESULT=` token。标签、描述、打印出来的话、注释都不在里面，这是故意的。

所以文本批次的规定是机械的：只改字，指纹逐字节不变。指纹动了，就说明这一批改了结构，
而 diff 会点名是哪个键动了。

- 基线：`ac5d65a`，取自本轮第一次文本改动之前，因此它描述的是"CI 证明过的流水线"，
  不是"希望它变成的样子"。
- 重生成：
  `CI_TEXT_FINGERPRINT_WRITE=1 CI_TEXT_FINGERPRINT_REASON='<为什么>' bash tests/modules/ci/test_ci_text_conventions.sh`。
  没给理由时写入器直接拒绝执行——头部什么都不说的基线，没人能复核。
- 重生成自成一个提交，头部写 `# reason: <为什么结构变了>`，并且指纹 diff 要进评审。
  把重生成混进文本批次，正好抹掉这个文件唯一要展示的东西。

机器判定：指纹等于基线，且基线头部 `reason:` 非空。

## 测试管不到的事

六条规则好断言。这条不好，所以它是给读 diff 的人的清单：

- 这个标签说的是"结论"，还是"产生结论的动作"？`S2 image - four partitions` 是结论；
  `Run the image step now` 不是。
- 一遍读下来就能懂吗？短不等于够：`Verify the abandon moved the next boot to slot a`
  很长，但一遍就懂。
- 数字贴着单位吗——`638,976 bytes`、`53.7 MB`；出现时间时，时区写了吗？
- 有没有话说两遍？重复 job 名的 step summary 就是该删掉的那一行。
- 刚看到失败的人知道下一步去哪吗？`next command` 就是为这个存在的，所以它永远不为空。
- 有没有读者当场就要做的动作？给一行动作——`Revert the squash commit to restore the previous
  pin`。解释"为什么这样设计"属于 `docs/`，不属于一份只看一遍、还赶时间的正文。

## 怎么改这份契约

一条规则要在同一批里改三个地方：这一页、它的译文、以及执行它的断言。没有被断言的规则
只是偏好，而偏好该写在"测试管不到的事"那一节，不在上面的清单里。如果某次改名让某条规则
不实用，就改规则并在这里写清理由——契约是拿来读的，不是拿来辩护的。

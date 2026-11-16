# 每日上游 watch

[English](daily-upstream-watch.md) | **简体中文**

每日 watch（[`upstream-watch.yml`](../.github/workflows/upstream-watch.yml)）就是自动发布线：它发现上游
新的正式版 ImmortalWrt release，用普通流水线构建它、移动 pin、合并、打 tag 并发布 —— 全部在一次 run
图里完成，因为用 `GITHUB_TOKEN` 推的 commit 或 tag 不会触发任何 workflow。watch 是什么、两条发布线差在
哪里写在 [ci-release-lines.zh-CN.md](ci-release-lines.zh-CN.md)；本页是运行手册：它什么时候跑、怎么读
一次 run、怎么彩排、失败怎么恢复、需要什么前置条件，以及它花多少钱。

## 它什么时候跑

触发是 [`upstream-watch.yml`](../.github/workflows/upstream-watch.yml) 里的一条 schedule：

```yaml
on:
  schedule:
    - cron: "0 16 * * *"
```

`0 16 * * *` 是 UTC 16:00，也就是北京时间的零点。这是**名义**时间，不是实际启动时间：GitHub 的
`schedule` 是 best-effort，队列忙的时候就晚。在本仓库实测，这个 workflow 之前声明的 20:00 UTC
cron，实际启动时间是：

| 排给 20:00 UTC 的日期 | 实际启动（UTC） | 延迟 |
|---|---|---|
| 2026-11-11 | 2026-11-12T00:48 | +4.8 h |
| 2026-11-12 | 2026-11-13T00:34 | +4.6 h |
| 2026-11-13 | 2026-11-14T00:34 | +4.6 h |
| 2026-11-14 | 2026-11-14T23:30 | +3.5 h |

延迟在 3.5 到 4.8 小时之间，这正是 cron 现在写 16:00 UTC 而不是 20:00 UTC 的原因：同样的延迟下，
构建会落在北京时间 04:00 附近，而不是上午。04:00 是预期，不是保证 —— 队列更堵时会更晚，队列空闲时
会更早。workflow 自己的注释记下了这次实测和目标时间。

关于触发还有两件小事：

- schedule 读的是默认分支上的文件，所以改 cron 只有在合并之后才生效；
- `workflow_dispatch` 随时可以启动同一张图，彩排和恢复走的就是它（见第 3、4 节）。

## 三种结果

一次 run 只可能是三种形状之一。是哪一种，看 run 列表和 job 列表就知道，run 页面的 job 图也会直接说出来。

| 结果 | 图 | 怎么读 |
|---|---|---|
| 有新版本 | `detect` -> `bump` -> `build` -> `locks` -> `merge` -> `publish` | run 绿，`bump/build/locks/merge/publish` 都跑了，之后多出一个裸 `<X.Y.Z>` tag 与一个 release |
| 没有新版本 | 只有 `detect` | run 绿，其余 job 全是 `skipped`，没有建分支、没有 tag、没有 release |
| 失败 | 任一 job 失败或被取消 | run 红，并且有一个标题为 `[auto-release] <version>`、label 为 `auto-release` 的 issue |

第一种形状里各个 job 按顺序做这些事：

- `detect` 找最新的上游正式版并与 pin 比较，同时报告 merge 状态（base 分支的 pin、merge commit、tag）；
- `bump` 只在 `auto/upstream-<version>` 上改 `.github/upstream-pin.conf`，并向 base 分支开或更新一个
  pull request；它从不直接推 `main`；
- `build` 以 `upstream_version=<新版本>` 调 [`ci.yml`](../.github/workflows/ci.yml)，同一个 run 里用同样
  五个阶段证明新基线；
- `locks` 从取回的上游文件派生三个 lockfile、提交到分支，再用 `CI_LOCK_STRICT=1` 断言**已提交**的那三份；
- `merge` 读 merge 状态、守 diff（只允许四个文件变动）、squash 合并并删分支，然后在 API 报告的那个
  merge commit 上推一个 annotated 裸 `<X.Y.Z>` tag；
- `publish` 以 `tag-policy: bare` 调 [`release-publish.yml`](../.github/workflows/release-publish.yml) ——
  与代码线同一份实现、同一道 preflight。

读 run 页面之前有两点值得知道：

- 自动线的 `publish` 只等 `detect` 与 `merge`，所以一次绿的 watch run 证明的是构建与合并，而不是
  「这个 release 能装在上一个 release 之上」。两道升级门
  （[`ci-upgrade-gates.yml`](../.github/workflows/ci-upgrade-gates.yml) 的 `cross` 与 `same-base`）接在
  代码线的 [`release.yml`](../.github/workflows/release.yml) 上，它的 `publish` 是
  `[build, cross, same-base]`；
- `skipped` 有两种含义。安静的一天里除 `detect` 以外的 job 全是 `skipped`，这就是成功的形状；
  而在门里，被跳过的证明不算通过的证明，门会红。

回答三个问题分别用这些命令：

```sh
# 最近几次 run，从新到旧 —— 「今天它有没有做事」的答案
gh run list --workflow upstream-watch.yml --limit 5

# 一次 run 的细节：哪些 job 跑了、各自怎么结束
gh run view <run-id> --json jobs --jq '.jobs[] | "\(.name): \(.conclusion)"'

# 一次绿的 run 建出来的 release
gh release view <version> --json tagName,isDraft,publishedAt,assets

# 红 run 唯一留痕的地方
gh issue list --label auto-release --state open
gh run view <run-id> --log-failed
```

安静的一天还顺带回答「watch 还活着吗」：50 天没有任何活动时，`heartbeat` job 会推一个
`heartbeat-YYYYMM` tag，对 GitHub 而言这是活动，而它不是 `v*` tag。它出现在 tag 列表里：

```sh
git ls-remote --tags origin 'heartbeat-*'
```

## 彩排一次运行

彩排就是同一个 workflow，指定版本、打开 `dry-run`、给一个临时 base：

```sh
gh workflow run upstream-watch.yml --ref main \
  -f version=25.12.1 \
  -F dry-run=true \
  -f base=rehearsal/upstream-watch
```

布尔输入用 `-F`；用 `-f` 会把字符串 `"true"` 传给布尔字段。

| 输入 | 默认 | 它做什么 |
|---|---|---|
| `version` | 空 | 把这个正式版当成新版本，而不是去发现。按 pin 的规则校验：`X.Y.Z`，上游大版本至少 25。设了 `resume` 时必填 |
| `dry-run` | `false` | 彩排：`merge` 跳过 squash 合并与 tag，`publish` 建成 draft release 而不是正式 release |
| `base` | `main` | PR 开向并合并进的分支。`dry-run` 打开时 `bump` 拒绝 `main` 或 `master`，所以彩排必须指定临时 base |
| `resume` | 空 | `merge` 或 `publish`：续跑一次失败的 run（见第 4 节）。留空表示「去发现新版本」 |

指定的版本不能已经等于 pin：那样 `detect` 会以「the forced version is already the pin; nothing to
rehearse」拒绝，并指向用 `resume` 恢复已经合并过的 release。彩排要挑一个 pin 没有写着的正式版，
例如上一个版本。

彩排逐 job 会做什么：`detect` 接受指定版本而不是去发现；`bump` 建出 `auto/upstream-<version>` 并向
临时 base 开 pull request，临时 base 不存在时用这次 run 的 commit 建出来；`build` 为那个上游版本跑
普通流水线；`locks` 派生并提交三个 lockfile 再断言它们；`merge` 读 merge 状态、守 diff，然后
**同时跳过 squash 合并与 tag** —— run summary 会写出跳过的是哪一步、为什么；`publish` 上传并校验
字节，建成 **draft** release。

彩排不做的事：

- **不合并**：临时 base 分支不会被推进，没有任何 pull request 被合并；
- **不打 tag**：彩排前后远端 tag 集合逐字节相同。

它会留下什么，以及怎么清：

| 留下的东西 | 清理 |
|---|---|
| `auto/upstream-<version>` 与一个开着的 pull request | `gh pr list --head auto/upstream-25.12.1`，然后 `gh pr close <number> --delete-branch` |
| 彩排自建的临时 base 分支 | `git push origin --delete rehearsal/upstream-watch` |
| 一个 draft release | `gh release delete 25.12.1 --yes` |

draft release 不会创建 tag，所以 `--yes` 就够清掉它；`--cleanup-tag` 只在 release 的 tag 已存在时才需要。
绝不要为了让彩排干净去删 `v*` tag：`v*` 属于另一条发布线，它的 release 不是彩排残留。

彩排可以重复：同样的 dispatch 会替换上次建的分支，lockfile 步骤在文件已经描述该 release 时变成空操作，
`publish` 会删掉再重建 draft 而不是拒绝（它只在同名版本已经是**正式** release 时才拒绝，而彩排不可能产生
那种状态）。

## 失败后怎么恢复

红的 run 会开或更新一个 issue：标题 `[auto-release] <version>`，label `auto-release`，正文里有失败的
job、run URL 和两套恢复脚本。动手前先读三个字段：

| issue 里的字段 | 含义 |
|---|---|
| `base pin` | base 分支当前写着的 pin。等于 `<version>` 就说明 squash 合并已经落地 |
| `merge commit` | 这个 pull request 合并成的那个 commit（已知时） |
| `tag pushed` | 远端 tag 是否已经存在，以及它指向哪个 commit |

这三个事实不依赖 issue 也能读，因为它们正是只读子命令 `merge-state` 打印出来的东西：

```sh
bash scripts/ci/upstream-watch.sh merge-state 25.13.0
```

**合并之前** —— base 分支没有这个 pin，tag 也不存在。整段可以重跑；恢复用的 dispatch 会被明确告知
它在恢复哪个 release，因此不会去重新发现一个：

```sh
gh workflow run upstream-watch.yml -f version=25.13.0 -f resume=merge
```

`resume=merge` 会把该版本的整张图再跑一遍。它是幂等的，重复一个已经成功的步骤是安全的：分支用
`--force-with-lease` 推，lockfile 步骤在文件已经描述该 release 时什么都不做，base 分支已经写着自己
这个 pin 时跳过 squash 合并，tag 已经指向 merge commit 时也不动它。

**合并之后** —— base 分支已经写着这个版本，或者 tag 已经存在。这时没有「重来」：`detect` 会看到 pin
已经是那个 release，而普通重跑也无法撤销一次 squash。改为只把发布那一半做完：

```sh
gh workflow run upstream-watch.yml -f version=25.13.0 -f resume=publish
```

`resume=publish` 跳过发现，报告它从什么状态继续（`mode=resume`、`base pin`、`merge commit`、
`tag pushed`），复用已经合并的 pin 与已经推上的 tag，不会再合并、也不会再打 tag。它同样可以安全重
复：已经指向 merge commit 的 tag 是空操作，已经存在的正式 release 是重传覆盖（draft 会被转正）。

**发布本身错了的时候** —— squash 合进去的内容不对，或者 tag 必须换掉。这是唯一要删 tag 的路径，而且
是人工动作：

```sh
gh release delete 25.13.0 --yes --cleanup-tag   # 同时删掉 release 与它的 tag
git revert --no-edit <merge-commit>
gh workflow run upstream-watch.yml -f version=25.13.0
```

workflow 自己永不删 tag、也永不 force push tag；`resume=merge` 遇到已存在的 tag 会直接拒绝。

**幂等规则。** 本仓库的 tag 不可变。如果该版本的 tag 已经存在、却指向和本次要发布的合并不同的
commit，run 就会失败 —— `merge-state` 以「tags are immutable, refusing to force one」停下 —— tag 永远
不会被移动或覆盖。这也解释了为什么恢复要带同一个版本而不是新版本：版本号是 merge 与 tag 的标识，
恢复就从这个标识继续。

## 前置条件

watch 不用任何 secret；下面每一条都是仓库或组织配置，只有它们成立，自动线才能工作。

- **仓库是公开的（PUBLIC）。** 公开仓里长期没有活动的 scheduled workflow 会在 60 天后被停用，那等于
  把自动发布线悄悄关掉。`heartbeat` job 存在的唯一理由就是这个：`CI_HEARTBEAT_INTERVAL_DAYS`（默认
  50）天内既没有 heartbeat tag、也没有 release tag、也没有碰过 pin 的提交时，它推一个
  `heartbeat-YYYYMM`。名字按 `^heartbeat-[0-9]{6}$` 断言，workflow 拒绝推任何匹配 `v*` 的东西，所以
  心跳永远不会启动一次发布。
- **默认 `GITHUB_TOKEN` 有 write 权限。** Settings -> Actions -> General -> Workflow permissions 必须是
  可读可写。每个 job 只把自己要写的那部分收窄（`contents: write`、`pull-requests: write`、
  `issues: write`），而仓库或组织的默认值是只读时，`bump` 会在推分支或开 PR 时失败。
- **`main` 不要求「token 建的 PR 满足不了的检查」。** 用 `GITHUB_TOKEN` 推的分支、PR 或 tag 不会触发
  任何 workflow（GitHub 的递归保护），所以 `main` 上如果设了必过状态检查，那个检查永远不会上报，
  `gh pr merge` 会一直等下去；要求人工 approve 的分支保护同理，除非有人去点。既不要求状态检查、也
  不要求 review 的保护，watch 可以照常工作。

## 成本与回滚

每个跑步骤的 job 都带 `timeout-minutes`。watch 自己的 job：

| job | 上限 |
|---|---|
| `detect` | 10 min |
| `heartbeat` | 10 min |
| `bump` | 10 min |
| `locks` | 45 min |
| `merge` | 15 min |
| `issue` | 10 min |

`build` 自己没有上限，因为它调的是可复用 workflow，用的是流水线的预算。五阶段流水线实测端到端
18 分钟（run `43708356221`，其中 S5 一个阶段就 17 分钟）。`publish` 用的是 `release-publish.yml`
的 35 分钟。

所以一次绿的 run 花多少，取决于它走哪条路：

- **没有新版本**：只有一个 `detect` job。上一版 graph 的三次定时 run 各花了 8 到 14 秒 ——
  这是「watch 还活着」最便宜的证明；
- **有新版本**：新基线的构建（实测 18 分钟）加上 `locks`、`merge`、`publish`。把上面那些上限加起来
  是最坏情况，不是预期值；
- **一次 tag 发布**还要额外付两道升级门的钱，而 watch 本身不跑它们：cross 门 35 分钟的 job 上限与
  same-base 门 25 分钟的上限。

**回滚一个已经发布的版本。** tag 是已经发布出去的事实，本仓库不移动 tag —— `merge-state` 存在的
意义就是拒绝这件事。支持的两种做法是：

- **向前发。** 在默认分支上 revert 那次 squash commit，把 pin 与三个 lockfile 恢复回来，然后用下一个
  版本修正：代码线打一个新的 `v*` tag，上游线等下一个正式上游 release。已经发布的 tag 与 release
  作为历史保留。revert 并不会让同一个版本重新可发布：tag 仍然指向旧的 merge commit，所以之后为这个
  版本跑的 run 会在 tag 检查处停下，而不是再发一次。
- **人工、刻意地删 tag。** 只在 tag 与 release 本身错了时，而且只能由人来做：
  `gh release delete <version> --yes --cleanup-tag`，再 revert squash，再 dispatch 一次普通 run。
  workflow 永远不会自己做这件事。

如果错的是用户已经装上的那个版本，答案是发一个新版本，而不是收回旧版本：已经装好的机器不会再去查一个
曾经存在过的 tag。

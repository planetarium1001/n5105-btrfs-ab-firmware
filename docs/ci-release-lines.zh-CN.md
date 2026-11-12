# 两条发布线

[English](ci-release-lines.md) | **简体中文**

固件从本仓库发布出去只有两条路。**代码线**发的是我们自己的版本：推一个 `v0.0.9` tag，release
就出来了。**上游线**发的是新的 ImmortalWrt 基线：每日 watch 发现上游新的正式版，构建它、移动
pin、合并、然后用裸版本号（`25.13.0`）发布。

两条线在触发方式和「tag 必须证明什么」上不同，在「发布是什么意思」上不能不同：两者都调
[`release-publish.yml`](../.github/workflows/release-publish.yml)，而它在创建任何东西之前先跑
[`release-preflight.sh`](../scripts/ci/release-preflight.sh)。两个调用者、一份实现，这是两条线
不会漂移的原因，也是 watch 自动发的 release 与手发的那次被同样检查的原因。

## 两条发布线并列对比

| | 代码线 | 上游线 |
|---|---|---|
| 触发 | push `v*` tag（`release.yml`） | `schedule`（`0 20 * * *`），或 `upstream-watch.yml` 的 `workflow_dispatch` |
| tag 形状 | `v<X.Y.Z>`，例如 `v0.0.8` | 裸 `<X.Y.Z>`，例如 `25.13.0` |
| `VERSION` | tag 必须等于它：tag 去掉 `v` 就是本次发布的平台版本 | 发布不改它；它必须仍然是镜像里记录的那个平台版本 |
| 构建哪个上游 | `.github/upstream-pin.conf` 里的 pin；不传版本输入 | `detect` 刚发现的版本，作为 `upstream_version` 传给 `ci.yml` |
| 构建 | `ci.yml`，以 `workflow_call` 调用 | `ci.yml`，以 `workflow_call` 调用，且在同一次 run 里 |
| 发布入口 | `release.yml` 以 `tag-policy: v` 调 `release-publish.yml` | watch 的 `publish` job 以 `tag-policy: bare` 调它 |
| release 标题 | `N5105 AB firmware {tag}` | `ImmortalWrt N5105 A/B firmware {tag}`；由 publisher 按 `tag-policy` 派生，两个调用点都不传标题 |
| 资产 | `n5105-ab-<upstream>-install.img.gz`、`n5105-ab-<upstream>-upgrade.tar`、`SHA256SUMS` | 同样三个 |
| 失败落在哪 | tag 上的 run 变红；什么都没发布，tag 留着 | 一个标题 `[auto-release] <version>`、label `auto-release` 的 Issue |

资产名带的是上游基线与角色，从不带我们自己的计数器；两条线用同一个脚本
（`scripts/ci/release.sh`）产出它们。`release-notes.md` 写在资产旁边并成为 release 正文：页面上下载得到的
是三个资产，正文就是这三个文件上面的那段字，不是第四个文件。

`dry-run: true` 在两条线上含义相同：每一步都跑、字节都上传，但 release 建成 **draft**。彩排和
真发布只差这一点。

## tag 必须证明什么

tag 是一个主张，preflight 就是核对这个主张的地方。`release-publish.yml` 先挂上镜像、证明镜像里
的 initrd 就是生产那份，再跑 preflight，这些都在 `gh release create` 之前；拒绝就是非零退出，不是
一条警告，而且什么都没创建。

两条 policy 共有的检查：

- 镜像里的记录 `ab/image.json` 写着 `"kind": "boot"` —— 探针镜像直接被拒；
- 要发布的那份 initrd 打印 `S3 boot init`，且不含 `S1-RESULT` —— 这一条是 workflow 自己的
  `Verify the image is bootable` 步骤做的，不是 preflight；
- payload 清单是 `ab-payload/1`，并写明了 `rootfs` 版本；
- payload tar 里确实带着每个成员，且摘要与清单一致；
- payload 带着 `boot.tar`，里面有 `grub.cfg` 和一个 GRUB core：一台机器更新不了镜像的，不算发布。

`--tag-policy v`（代码线）额外断言：

- tag 匹配 `^v[0-9]+\.[0-9]+\.[0-9]+$`；
- 平台版本（默认读 `VERSION`，调用者也可以显式给）等于 tag 去掉 `v`；
- `ab/image.json` 记录的 `platform_version` 就是这个平台版本；
- `ab/image.json` 的 `upstream_version` 等于 payload 清单里的 `rootfs`。

`--tag-policy bare`（上游线）额外断言：

- tag 匹配 `^[0-9]+\.[0-9]+\.[0-9]+$`；带 `v` 前缀属于另一条线，在这里被拒；
- `ab/image.json` 的 `upstream_version` 等于 tag；
- payload 清单的 `rootfs` 等于 tag；
- `ab/image.json` 的 `platform_version` 等于平台版本，且随包的 `VERSION` 文件仍然写着这个平台版本。
  换句话说，上游线换的是基线，平台版本原封不动：一个悄悄改写系统版本的 release 会把所有升级过
  的机器的平台名改掉。

所有不一致会在一次 run 里全部报出来，形式是 `release-preflight: <原因>` 行，所以一次就能看到
全部问题而不是第一个。读不出来的输入会立刻终止 run：那是调用写错了，不是对 release 的判断。

镜像检查背后的历史：v0.0.6 与 v0.0.7 把 S2 的 `image-probe` 发了出去，每台真机都在 GRUB 菜单
关机并留下 `S1-RESULT=fail reason=no-device-node`。现在发布取的是 `image-install`（S3 的产物，
用生产 initramfs 构建的那份），并且在发布前打开它读出它自己的记录。

## 上游 watch

`upstream-watch.yml` 是一个 run 图，因为用 `GITHUB_TOKEN` 推的 commit 或 tag 不会触发 workflow：
「推 bump、让 CI 构建、让 tag 发布」这种设计根本不可能工作。

| job | needs | 权限 | 干什么 |
|---|---|---|---|
| `detect` | - | `contents: read` | `scripts/ci/upstream-watch.sh detect` 找最新的**正式版**（`X.Y.Z`；候选版、快照版和低于 25 大版本的都排除），输出 `changed`、`version`、`current_pin`；`matrix-select.sh` 选出新版本加上它之前三个正式版；`heartbeat-tag.sh --dry-run` 判断心跳是否到期 |
| `heartbeat` | `detect` | `contents: write` | 没有新版本且心跳到期时推 `heartbeat-YYYYMM`。见下文 |
| `bump` | `detect` | `contents: write`、`pull-requests: write` | 在 `auto/upstream-<version>` 分支上只改 `.github/upstream-pin.conf` 并开 PR。它永不直接 push `main` |
| `build` | `detect`、`bump` | `contents: read`、`actions: read` | 以 `upstream_version=<新版本>` 调 `ci.yml`，新基线在同一次 run 里由同样的五个阶段构建 |
| `locks` | `detect`、`bump`、`build` | `contents: write` | 从 `upstream-files` 产物派生三个 lockfile，提交到分支，然后用 `CI_LOCK_STRICT=1` 断言**已提交的那份** |
| `merge` | `detect`、`bump`、`build`、`locks` | `contents: write`、`pull-requests: write` | base 分支已 pin 该版本时跳过；守护 diff；squash 合并并删分支；用 PR 的 `mergeCommit.oid` 打 tag |
| `publish` | `detect`、`merge` | `contents: write`、`actions: read` | 以 `tag-policy: bare` 调 `release-publish.yml`，矩阵候选作为补充说明 |
| `issue` | 上面全部七个 | `contents: read`、`issues: write` | 在 `failure() || cancelled()` 时跑，写下唯一要看的地方 |

**一次失败的 run 只留一处痕迹。** `issue` job 把 Issue 标题固定为 `[auto-release] <version>`，
label 为 `auto-release`。同名的 open issue 已经存在就 comment，而不是再开一个；最后以非零退出结束，
让这个 job 自己也是红的。正文里带各 job 的结果和 run URL。

**心跳 tag。** 公开仓库里的 scheduled workflow 在 60 天没有活动后会被禁用，那会让自动发布线悄悄
停摆。`heartbeat-tag.sh` 只在 `CI_HEARTBEAT_INTERVAL_DAYS`（默认 50）天里什么都没发生时创建
`heartbeat-YYYYMM`，基准取三者中最新的一条：上一个心跳 tag、上一个裸版本 release tag、上一次动
pin 的提交。名字断言 `^heartbeat-[0-9]{6}$`，并且 workflow 拒绝推送任何匹配 `v*` 的 tag —— 一个
`v*` tag 会拉起代码线，发布一个从零构建出来的固件版本。存在性判断靠 tag 历史，所以那个 job 的
checkout 带 `fetch-tags: true` 与 `fetch-depth: 50`。

**合并。** 自动改动是一个分支加一个 PR，落地前重新核一遍：

- base 分支已经 pin 了这个版本，说明发布在这次 run 构建期间已经发生过，`merge` 以 `skip=true`
  停下，于是两次重叠的 run 收敛到同一个答案而不是合并两次；
- `Guard the diff` 只允许四个文件：`.github/upstream-pin.conf`、
  `scripts/ci/initramfs-tools.lock.json`、`scripts/ci/kmod-closure.json`、
  `scripts/ci/runtime-closure.json`。出现别的文件，说明这个分支带着没人构建过的改动；
- 合并方式是 squash 并删除分支，所以回滚就是 revert 一个 commit；
- tag 是 annotated 的，指向 API 为那个 PR 报出的 `mergeCommit.oid`，而不是此刻 base 分支指向的
  位置。

**为什么这个 workflow 不声明 `concurrency`。** GitHub 不能嵌套 concurrency 组：在声明了组的
workflow 里调用另一个也声明了组的 reusable workflow，这次调用会静默消失，job 根本不出现在 run
里。它构建用的 `ci.yml` 声明了组，所以 watch 不声明。单飞能力并没有丢 —— `merge` job 会重新读
base 分支上的 pin，发布已经发生过就停下。

## 实例 v0.0.8

代码线完整走通过一次。run `43238859287`（`Firmware CI - release`，`event=push`，
`headBranch=v0.0.8`）以十二个 job、全部 `success` 结束：流水线的十一个（`read the platform
version`、`resolve upstream`、`static checks`、`fetch upstream`、`assemble payload`、`S1` 到
`S5`、`report`）加上 `publish / publish the release`。

release `v0.0.8` 是发出去的、不是 draft：`isDraft=false`、
`publishedAt=2026-11-12T14:51:00Z`，标题 `N5105 AB firmware 0.0.8`，三个资产：

| 资产 | 字节数 |
|---|---|
| `n5105-ab-25.12.2-install.img.gz` | 53872414 |
| `n5105-ab-25.12.2-upgrade.tar` | 23500800 |
| `SHA256SUMS` | 193 |

这就是代码线一次发布的样子：`VERSION` 写着 `0.0.8`，tag 是 `v0.0.8`，镜像记录的平台版本是
`0.0.8`、上游是 `25.12.2`，preflight 三者都认，发出去的镜像是 S3 用生产 initramfs 构建的那一份。

这两组事实可以重新取出来：

```sh
gh run view 43238859287 --json name,event,headBranch,conclusion
gh release view v0.0.8 --json tagName,isDraft,publishedAt,assets
```

上游线目前还没有发布实例 —— 本仓库的 tag 只有 `v0.0.5` 到 `v0.0.8`：

```sh
gh api repos/:owner/:repo/tags --jq '.[].name'
```

## 什么时候用哪条

**代码线**用来发布我们自己的平台版本。`VERSION` 是版本的唯一来源，所以先改它、先提交，tag 从它
推导出来：

```sh
tr -d '[:space:]' < VERSION
git tag -a "v$(tr -d '[:space:]' < VERSION)" -m "release $(tr -d '[:space:]' < VERSION)"
git push origin "v$(tr -d '[:space:]' < VERSION)"
```

push tag 就是启动构建的那一下，不需要再派发任何东西。与 `VERSION` 不一致的 tag 会被 preflight
拒绝，release 不会出现。

**上游线**用来换 ImmortalWrt 基线，通常什么都不用做：`schedule` 每天 20:00 UTC（北京时间 04:00）
跑一次，没有新版本时以成功结束。

```sh
gh workflow run upstream-watch.yml --ref main
```

两个输入是为彩排和刻意的手动跑准备的：

| 输入 | 它改变什么 |
|---|---|
| `version` | 把这个正式版当成新版本，而不是去发现；按 pin 的规则校验，所以必须是 `X.Y.Z` |
| `dry-run` | 合并进 `base` 指定的分支并创建 draft release；打开时 `bump` job 拒绝把 `main` 或 `master` 当 base |
| `base` | PR 开向并合并进的分支；默认 `main` |

所以彩排要指定一个临时 base，而且什么都不发布：

```sh
gh workflow run upstream-watch.yml --ref main -f version=25.13.0 -F dry-run=true -f base=rehearsal-25.13.0
```

回答「今天自动化做了什么」的命令是这个 workflow 的 run 列表；回答「它挂了吗」的命令是
`auto-release` 的 issue 列表：

```sh
gh run list --workflow upstream-watch.yml --limit 5
gh issue list --label auto-release --state open
```

两条线都用 [`ci.yml`](ci-pipeline.zh-CN.md) 构建，所以谁都不可能发布一个五个阶段没证明过的东西。

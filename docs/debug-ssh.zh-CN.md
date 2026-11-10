# SSH 交互调试

[English](debug-ssh.md) | **简体中文**

## 这个入口是什么

`ci-debug.yml` 是人工调试入口，不是流水线阶段。它装上引导类阶段需要的工具，跑与它们相同的 `scripts/ci/` 阶段，然后把 runner 交给一个可以 SSH 登录的会话。会话由 `owenthereal/action-upterm` 提供，钉在提交 `6c2d60e09009f59cb4c45c88767c78701f14d121`（v2.8.1）上。

- 触发：只有 `workflow_dispatch`。没有 `push`、没有 `pull_request`、没有 `workflow_call`。
- 门禁：没有。它不判定任何东西、不出结论，也没有别的 workflow 调用它。它留下的东西都是短命的：运行**摘要页**上的连接信息、把同一条指令写成 `debug-session` 产物（1 天）、以及保留 7 天的 `debug-<stage>-logs`（构建日志与会话首次启动的 guest 控制台）。
- 时长：三道上限——会话步骤 `timeout-minutes: 10`、keep-alive 步骤 `timeout-minutes: 150` 且即使没人断开也会在 140 分钟时自己收手、job 240 分钟。
- 访问：`limit-access-to-actor: true` 配合 `full-access: true`，只有派发者自己的 GitHub SSH 密钥能进入会话，且这些密钥可以执行命令、传输文件、转发回环端口。

上面任何一条不再成立时 `scripts/check_design.py debug-ssh` 会失败，因此"有人把它接到了 `push` 上"是一次红色的设计校验，而不是一条评审意见。

## 为什么需要它（实测）

S1/S2/S3 是绿的，S4/S5 不是，而它们的失败需要从内部观察一次引导，而不是更长的日志。来自 run `42815980945`（2026-11-10）：

| Job | 墙钟 | 引导步骤 |
|---|---|---|
| s4 | 5 分 01 秒 | 四次引导分别 61 / 55 / 57 / 56 秒 |
| s5 | 失败 | 第 3 次引导用满了 900 秒的 `CI_QEMU_TIMEOUT`，然后失败 |

一次 push-and-wait 往返大约十分钟，而一次往返只买到一位信息：过或不过。一个会话拿到的是串口控制台、ESP、loop 设备和"先试一条命令再写代码"的机会。s4 job 从 checkout 到镜像就绪只要 62 秒，这正是"先把环境备好再进会话"的价值：最贵的一段在你连上之前已经跑完。

## 怎么触发

命令行，务必从 `main` 派发：

```sh
gh workflow run ci-debug.yml --ref main -f stage=s4 -f boot_timeout=1200
gh run list --workflow ci-debug.yml --limit 1
```

网页：**Actions** → **ci-debug** → **Run workflow**，分支选 `main`，再选 `stage`。

| `stage` | 进会话之前会跑什么 |
|---|---|
| `none` | 只装工具。最便宜的会话，用于读脚本、探 runner 能力。 |
| `build-disk` | `resolve` → `fetch` → `kmods` → `esp-prepare` → `platform-runtime` → `initramfs` → `disk` → GRUB 预检。不引导。 |
| `s4` | `build-disk`，加网络 fixture 与第 1 次引导（空镜像、提交槽 a）。 |
| `s5` | `build-disk`，加升级载荷、s5 fixture 与第 1 次引导（全新安装是健康的）。 |

`boot_timeout` 就是那次引导的 `CI_QEMU_TIMEOUT`。默认 1200 秒，不是阶段 workflow 用的 900 秒，因为 s5 的第 3 次引导需要超过 900 秒。

从 `main` 派发是硬要求：`workflow_dispatch` 跑的是**所选 ref 上的**工作流文件，所以在某个分支上派发，下面每一步执行的都是那个分支的版本。只在你愿意让它执行任意命令的 ref 上派发。

## 怎么连上

会话步骤以 `detached: true` 运行 `owenthereal/action-upterm`，因此它把 `ssh-command`、`join-command`、`ssh-config` 作为步骤输出发布出来就返回，而不是把步骤挂住。紧随其后的步骤把 `ssh-command` 写进这次运行的**摘要页**，再下一步把同一行上传成 `debug-session` 产物。两者都能在浏览器里从运行页面拿到，脚本也能直接读产物，不需要有人盯着实时日志。

**用的是 upterm，不是 tmate，这是有意的。** tmate 自己的 README 写明："the public tmate servers (ssh.tmate.io) were shut down in July 2025, so tmate no longer works out of the box"（公开 tmate 服务器已于 2025 年 7 月关停，因此 tmate 开箱即用不再成立）。本仓库实测到的正是这个：每次会话尝试都挂满整段超时，因为 `tmate wait tmate-ready` 从未变成就绪。`owenthereal/action-upterm` 是仍在维护的替代品，而且保住了这里唯一重要的性质——会话只由派发这次运行的人的 GitHub 密钥授权。不要再把 tmate 步骤加回来：它已经没有公开中继可连。

摘要页里的那段长这样：

```
## Interactive session
Connect with your own key (limit-access-to-actor):
ssh session:<token>@uptermd.upterm.dev
```

```sh
ssh session:<token>@uptermd.upterm.dev
# 用的不是默认私钥时：
ssh -i ~/.ssh/id_ed25519 session:<token>@uptermd.upterm.dev
```

`limit-access-to-actor: true` 的语义是：upterm 只授权**触发（或重跑）这次运行的用户**在 GitHub 账号上登记的公钥。

- 你的 GitHub 账号上必须至少有一把 SSH 公钥（[添加公钥](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/adding-a-new-ssh-key-to-your-github-account)）。账号上没有公钥就没有可授权的东西，而 bot 账号从来没有：action 会跳过没有密钥的 actor，而不是把会话开放给所有人，所以由 bot 重跑出来的运行可能发出一串谁也进不去的连接信息。
- 日志是公开的、摘要页与产物是所有能看到这次运行的人都能读的，但连接串本身进不去：连接串是"地址"，私钥才是"凭证"。
- `full-access: true` 才让会话能调试：开了之后被授权的密钥可以执行命令、传输文件、转发回环端口。这里开启它，是因为"只能看着一次卡住的引导"不算调试会话，也因为 job 里没有值得保护的东西（见「安全」）。
- 摘要页与产物里只有 `ssh-command`。action 还会发布 `join-command` 与 `ssh-config` 两个输出，带的是同一个 token；workflow 两个都不复制，三者按一件凭证对待，任何一条都不要外贴。

## runner 上已经备好了什么

所有东西都在 `$RUNNER_TEMP/ci` 下，checkout 目录不动。

| 路径 | 内容 |
|---|---|
| `${RUNNER_TEMP}/ci/disk/n5105-ab-image.img` | 刚通过预检的 514 MiB GPT 镜像。 |
| `${RUNNER_TEMP}/ci/initramfs/boot.cpio.gz` | boot initramfs，含 `initramfs/boot/init` 与 s3 post 脚本。 |
| `${RUNNER_TEMP}/ci/fetch/upstream/kernel.bin` | GRUB 从 ESP 加载的上游内核。 |
| `${RUNNER_TEMP}/ci/esp`、`${RUNNER_TEMP}/ci/runtime` | 备好的 ESP 与 btrfs 运行时闭包。 |
| `${RUNNER_TEMP}/ci/logs/` | `debug-prepare.log`、`debug-fixtures.log`、`debug-boot1.log`。 |

准备步骤的 step summary 会打印同样的路径，直接复制即可，不用猜。

## 手工驱动一次引导

引导就是 `scripts/ci/qemu-smoke.sh` 加上阶段 workflow 传的那组环境变量，没有任何 CI 专属逻辑：

```sh
export CI_TMP_ROOT="${RUNNER_TEMP}/ci"
export CI_KERNEL="${CI_TMP_ROOT}/fetch/upstream/kernel.bin"
export CI_INITRAMFS="${CI_TMP_ROOT}/initramfs/boot.cpio.gz"
export CI_QEMU_DISK="${CI_TMP_ROOT}/disk/n5105-ab-image.img"
export CI_QEMU_MODE=uefi-disk
export CI_JUDGE_PREFIX=""
export CI_QEMU_CASE=manual
export CI_QEMU_TIMEOUT=1800
export CI_QEMU_STOP_PATTERN='^(ab-commit: committed slot=|ab-commit: stage=healthcheck-done .*result=fail|ab-commit: stage=commit .*result=fail|ab-boot: stage=boot result=fail)'
bash scripts/ci/qemu-smoke.sh
```

`CI_JUDGE_PREFIX=""` 让运行在模式处停下而不是断言判定行：guest 从不给自己打分。随后像阶段那样把镜像读回来：

```sh
export CI_IMAGE="${CI_TMP_ROOT}/disk/n5105-ab-image.img"
bash scripts/ci/grub-render.sh --verify-esp "${CI_IMAGE}"   # 状态文件与运行期槽文件是否一致
bash scripts/ci/ab-phase.sh --phase commit --slot a --expect-committed a --expect-pending none
bash scripts/ci/s5-phase.sh --phase toolchain --serial "${CI_TMP_ROOT}/qemu/serial-uefi-disk.log"
sudo losetup --find --show --partscan "${CI_IMAGE}"          # 手工挂 ESP
```

串口日志是 `CI_QEMU_DIR` 下的 `serial-<mode>.log`，上面那次引导对应 `${CI_TMP_ROOT}/qemu/serial-uefi-disk.log`。探针本该打印什么写在 `docs/lifecycle.md`，每个阶段的输入写在 `scripts/ci/README.md`。

要验证关于出货代码的假设，改 `scripts/` 或 `platform/` 下的文件后重跑引导：guest 内部看到的变化需要重建镜像（同样的环境跑 `bash scripts/ci/disk.sh`），而 `qemu-smoke.sh`、`ab-phase.sh`、`grub-render.sh` 可以对同一个镜像反复跑。

## 会话时长、成本与收尾

- GitHub 托管 job 的**硬上限是 6 小时**。这个 workflow 远早于此收手：会话步骤 10 分钟、keep-alive 步骤 150 分钟并在 140 分钟时自停、job 240 分钟。
- **action 自己声明了什么。** `action-upterm` v2.8.1 在所钉提交上的输入是 `limit-access-to-actor`、`limit-access-to-users`、`allow-exec`、`allow-forwarding`、`full-access`、`upterm-server`（默认 `ssh://uptermd.upterm.dev:22`）、`known-hosts`、`wait-timeout-minutes`、`upterm-version`、`detached`。其中没有任何一项是会话时长：时长来自步骤与 job 上的 `timeout-minutes`（本步骤 10 分钟），这也是设计校验断言存在、workflow 注释里写明的那一项。把上限挪进一个没人检查的 shell 字面量，等于没有上限。
- **`wait-timeout-minutes` 不是会话时长。** 它是 action 的 post 步骤（`post-if: '!cancelled()'`）等一个 guest 的耐心；detached 模式下这段等待发生在 job 末尾。detached 模式下不设或设为 `0` 意味着十分钟，所以这里写 `5` 是有意缩短，不是默认值。
- **runner 还活着时断线可以重连**：会话比一次 SSH 断开活得久，同一条指令还能再用。会话结束、到达 140 分钟上限或运行被取消之后它才失效。*未核实*：社区中继是否允许第二个并发 guest，以及第二个 guest 会看到什么；不要按"两个人同时看一个会话"来安排。
- **主动结束**：在 shell 里 `exit`，或者关掉 SSH 客户端，会话就结束了——post 步骤走完它的等待，keep-alive 步骤发现会话没了就返回，job 随之收尾。在界面里 Cancel 同样有效：keep-alive 特意用 `!cancelled()` 门控，所以取消会真的放掉 runner，而不是又睡一轮。
- **合上笔记本不等于关掉会话**：连接掉线不会让 runner 上的会话结束，它继续开着并照常计费。真正停掉它的是上面的时长上限，或者 Cancel。
- **成本**：会话打开期间占用计划内的一个并发 job（Free 20、Pro 40、Team 60、Enterprise 500）。忘了关的会话既烧 runner 分钟，也可能在忙时把真正的运行挤掉。
- **残留**：runner 是一次性 VM，那台机器不保留。留下来的是运行**摘要页**里的 SSH 指令、保存同一条指令的 `debug-session` 产物（1 天），以及保留 7 天的 `debug-<stage>-logs` 产物（启动证据）。一次重要的会话之后，在日志不再需要时把运行删掉：`gh run delete <run-id>`（或在界面删除该运行）。
- 每个分支只允许一个会话：`concurrency` 组是 `ci-debug-<ref>` 且 `cancel-in-progress: true`，因此第二次派发会顶掉第一次，而不是排队两个交互式 runner。

## 安全

仓库是**公开**的（`gh repo view --json visibility` 在 2026-11-10 报 `PUBLIC`），本节大部分结论由这一点决定。

| 问题 | 答案 |
|---|---|
| 会话默认谁都能连吗？ | 在本 workflow 里不是。action 用 `limit-access-to-*` 这几个输入来约束来客，所以 `limit-access-to-actor: true` 才是"没有派发者的密钥就连不上"的那一项；这里无条件设上，校验也会在它被删掉时报错。 |
| 谁能派发这个 workflow？ | 只有对该仓库有写权限的用户。其他人无法开启会话。 |
| 谁能连进会话？ | 只有触发或重跑这次运行的那个用户的 GitHub 公钥。已合并 PR 的作者、别的维护者都不行，除非是本人派发。bot 账号没有公钥，所以没有密钥的 actor 只会得到一个谁也进不去的会话。 |
| `full-access` 多给了什么？ | 被授权的密钥可以执行命令、传输文件、转发回环端口，因此这是一个真正的 shell，而不是只能看的画面。它只与 `limit-access-to-actor` 一起开启，并且发生在一个随后被销毁的 VM 内。 |
| 谁还在这条链路上？ | 默认中继 `uptermd.upterm.dev` 是第三方运营的社区服务：它为这次连接做中转，也能看到它。`upterm-server` 与 `known-hosts` 可以把它指到你自己的主机上，**自托管才是加固后的选择**——那是唯一"中继不是别人的机器"的形态。 |
| 那还是会泄露什么？ | SSH 指令本身（摘要页与 `debug-session` 产物）、步骤日志里打印 token 的那几行、串口日志、以及会话里敲的每一条命令，全部在公开的运行日志里。会话一旦打开，这条指令对"持有被授权密钥的人"就是凭证。默认假设日志是公开的，永远不要把带 secret 的 export 贴进去。 |
| 能被放宽吗？ | 只能靠改 workflow。托管 runner 上 `sudo` 不受限，因此会话里能装任何东西——但那只发生在一个随后被销毁的 VM 内，这也是它只能当调试工具、不能当安全边界的原因。 |

由上表得到两条规矩：

1. 从 `main` 派发，绝不在你不愿让其执行任意代码的分支上派发。
2. 会话结束后，日志不再需要时删掉这次运行——摘要页与产物随之一起消失。

## 为什么它不能替代 CI 门禁

会话不能证明仓库的任何事情：

- 它没有判定。`ci-debug` 的每一次预备引导都带 `continue-on-error`，最后一步是交互式 shell，所以一次"绿色"运行只意味着"会话开起来了"，不意味着"槽提交了"。
- 它不可复现。同一个提交上的两次会话看到的镜像可能不同，因为第二次是从第一次手工折腾过的镜像继续的。
- 它不跑在真正重要的事件上。`push` 与 `pull_request` 仍然走 `ci.yml` 及其阶段，`release.yml` 仍然由那些阶段构建发布。
- 被判定的路径没有移动：冻结的判定行、ESP 断言、`ci-s4.yml` / `ci-s5.yml` 里那四次带门禁的引导。会话里找到的修复要变成提交，而提交仍然必须让那些阶段变绿。

一个好习惯：用会话弄清"第 3 次引导为什么卡住"，写出让它不再卡住的最小改动，然后让下一次 push 作为证据。
